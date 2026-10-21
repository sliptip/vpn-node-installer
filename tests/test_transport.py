"""Transport regressions; optional real binaries via XRAY_BINARY / NGINX_BINARY."""
import contextlib
import io
import json
import os
import pwd
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from test_installer import INSTALLER, bash

SOURCE = INSTALLER.read_text()
HELPER = INSTALLER.with_name('clients.sh').read_text()
UID = '00000000-0000-4000-8000-000000000001'


def python_block(source, anchor):
    return source.split(anchor, 1)[1].split("<<'PY'", 1)[1].split('\n', 1)[1].split('\nPY', 1)[0]


def run_python(code, args):
    out = io.StringIO()
    with patch.object(sys, 'argv', ['test', *map(str, args)]), contextlib.redirect_stdout(out):
        exec(compile(code, '<installer-python>', 'exec'), {})
    return out.getvalue()


def inbound_payload(directory, port=10001):
    target = directory / 'payload.json'
    run_python(python_block(SOURCE, 'create_inbound(){'),
               [target, 'example', UID, 'default@vpn.example.test', port, '/client/api/v3', 'stream-one'])
    payload = json.loads(target.read_text())
    for key in ('settings', 'streamSettings', 'sniffing'):
        payload[key] = json.loads(payload[key])
    return payload


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class TransportTests(unittest.TestCase):
    def test_primary_and_bulk_links_agree(self):
        r = bash('summary vpn.example.test 192.0.2.1 /dashboard-example/ example "$1" default@vpn.example.test v3.10.2', UID)
        self.assertEqual(r.returncode, 0, r.stderr)
        primary = next(line for line in r.stdout.splitlines() if line.startswith('vless://'))
        with tempfile.TemporaryDirectory() as tmp:
            items = Path(tmp) / 'clients.json'
            items.write_text(json.dumps([{'client': {'id': UID, 'email': 'default@vpn.example.test'}}]))
            code = python_block(HELPER, "Готовые VLESS URL:")
            for transport, path, alpn in [('xhttp', '/client/api/v3', 'h3'), ('ws', '/client/api/v2', 'http/1.1')]:
                bulk = run_python(code, [items, 'vpn.example.test', path, transport, alpn, 'stream-one']).strip()
                parsed = urlsplit(bulk)
                query = parse_qs(parsed.query)
                self.assertEqual(query['type'], [transport])
                self.assertEqual(query['path'], [path])
                self.assertEqual(query['alpn'], [alpn])
                if transport == 'xhttp':
                    self.assertEqual(query, parse_qs(urlsplit(primary).query))
                    self.assertEqual(query['mode'], ['stream-one'])
                else:
                    self.assertNotIn('mode', query)

    def test_helper_rejects_transport_mismatch_before_mutation(self):
        code = python_block(HELPER, '# Fail before creating clients')
        with tempfile.TemporaryDirectory() as tmp:
            db = Path(tmp) / 'panel.db'
            conn = sqlite3.connect(db)
            conn.execute('CREATE TABLE inbounds (protocol TEXT, port INT, stream_settings TEXT, listen TEXT)')
            payload = inbound_payload(Path(tmp))
            conn.execute('INSERT INTO inbounds VALUES (?,?,?,?)',
                         ('vless', 10001, json.dumps(payload['streamSettings']), '127.0.0.1'))
            conn.commit()
            conn.close()
            run_python(code, [db, 10001, 'xhttp', '/client/api/v3'])
            for args in [(10001, 'ws', '/client/api/v2'), (10000, 'ws', '/client/api/v2'),
                         (10001, 'xhttp', '/wrong-path')]:
                with self.subTest(args=args), self.assertRaises(SystemExit):
                    run_python(code, [db, *args])


@unittest.skipUnless(os.environ.get('XRAY_BINARY') and os.environ.get('NGINX_BINARY'),
                     'Set XRAY_BINARY and NGINX_BINARY for real local QUIC integration')
class RealH3Tests(unittest.TestCase):
    def test_installer_templates_carry_vless_over_h3(self):
        """Use the actual payload, Nginx template and smoke-client config, isolated ports/files."""
        xray = str(Path(os.environ['XRAY_BINARY']).resolve())
        nginx = str(Path(os.environ['NGINX_BINARY']).resolve())
        with tempfile.TemporaryDirectory(prefix='vpn-h3-integration-') as tmp:
            root = Path(tmp)
            ports = [free_port() for _ in range(4)]
            http_port, tls_port, xray_port, socks_port = ports
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=vpn.example.test', '-addext', 'subjectAltName=DNS:vpn.example.test',
                            '-keyout', str(root/'key.pem'), '-out', str(root/'cert.pem')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            payload = inbound_payload(root, xray_port)
            # Test-only loopback destination. Production probes the node's public domain;
            # it keeps Xray's default private-address protection unchanged.
            server = {'log': {'loglevel': 'warning'}, 'inbounds': [payload], 'outbounds': [
                {'protocol': 'freedom', 'settings': {'finalRules': [
                    {'action': 'allow', 'ip': ['127.0.0.1/32'], 'port': str(http_port)}]}}]}
            (root/'server.json').write_text(json.dumps(server))
            template = SOURCE.split('write_final_nginx(){', 1)[1].split('<<EOF_NGINX\n', 1)[1].split('\nEOF_NGINX', 1)[0]
            rendered = bash('d=vpn.example.test; port=29999; panel=/dashboard-example/; no=/dashboard-example; '
                            'cat <<EOF_TEST\n' + template + '\nEOF_TEST\n').stdout
            rendered = (rendered.replace('listen 80;', f'listen 127.0.0.1:{http_port};')
                        .replace('listen 443 ', f'listen 127.0.0.1:{tls_port} ')
                        .replace('/etc/letsencrypt/live/vpn.example.test/fullchain.pem', str(root/'cert.pem'))
                        .replace('/etc/letsencrypt/live/vpn.example.test/privkey.pem', str(root/'key.pem'))
                        .replace('127.0.0.1:10001', f'127.0.0.1:{xray_port}')
                        .replace('/var/log/nginx/vpn-transport.log', str(root/'transport.log')))
            # All paths private; no root services, system configuration or DNS edits.
            dirs = '\n'.join(f'{kind}_temp_path {root}/{kind};' for kind in ['client_body', 'proxy', 'fastcgi', 'uwsgi', 'scgi'])
            (root/'nginx.conf').write_text(f'user {pwd.getpwuid(os.getuid()).pw_name}; daemon off; master_process off; pid {root}/nginx.pid;\n'
                f'error_log {root}/nginx-error.log; events {{}} http {{\n{dirs}\n'
                f"access_log off; log_format vpn_transport '$server_protocol $status';\n{rendered}\n}}")
            # Evaluate the config-building prefix of the production H3 smoke test.
            prefix = python_block(SOURCE, 'h3_smoke_test(){').split('\ntry:\n', 1)[0]
            ns = {}
            with patch.object(sys, 'argv', ['test', 'vpn.example.test', '/client/api/v3', 'stream-one']), \
                 patch.dict(os.environ, H3_TEST_UUID=UID):
                exec(prefix, ns)
            client = ns['config']
            client['inbounds'][0]['port'] = socks_port
            out = client['outbounds'][0]
            out['settings']['vnext'][0]['port'] = tls_port
            out['streamSettings']['tlsSettings']['certificates'] = [
                {'certificateFile': str(root/'cert.pem'), 'usage': 'verify'}]
            (root/'client.json').write_text(json.dumps(client))
            processes = []
            with (root/'process.log').open('w+') as logs:
                try:
                    for config in ['server.json', 'client.json']:
                        subprocess.run([xray, 'run', '-test', '-c', str(root/config)], check=True, stdout=logs, stderr=logs)
                    check = subprocess.run([nginx, '-t', '-p', tmp, '-c', str(root/'nginx.conf')], capture_output=True)
                    self.assertEqual(check.returncode, 0, check.stderr.decode())
                    for command in [[xray, 'run', '-c', str(root/'server.json')],
                                    [nginx, '-p', tmp, '-c', str(root/'nginx.conf')],
                                    [xray, 'run', '-c', str(root/'client.json')]]:
                        processes.append(subprocess.Popen(command, stdout=logs, stderr=logs))
                    for _ in range(3):
                        time.sleep(.3)
                        result = subprocess.run(['curl', '-fsS', '--noproxy', '', '--proxy', f'socks5h://127.0.0.1:{socks_port}',
                                                 '--max-time', '3', '-H', 'Connection: close', '-D', '-', f'http://127.0.0.1:{http_port}/health'], capture_output=True)
                        # The HTTP vhost redirects; a successful HTTP response still proves a VLESS round trip.
                        if result.returncode == 0:
                            break
                    logs.flush()
                    self.assertEqual(result.returncode, 0, result.stderr.decode() + (root/'process.log').read_text() + (root/'nginx-error.log').read_text())
                    self.assertIn(b'HTTP/1.1 301', result.stdout)
                    for _ in range(25):
                        if 'HTTP/3.0 200' in (root/'transport.log').read_text():
                            break
                        time.sleep(.2)
                    self.assertIn('HTTP/3.0 200', (root/'transport.log').read_text())
                finally:
                    for proc in reversed(processes):
                        proc.terminate()
                        try:
                            proc.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            proc.kill(); proc.wait()


if __name__ == '__main__':
    unittest.main()
