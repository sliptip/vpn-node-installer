"""Offline regression checks: no VPS services, credentials or external requests."""
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / 'install.sh'
PASSWORD = 'test-only-Ж\\"&+ % password'
PANEL_PATH = '/dashboard-example/'


def bash(body, *args, env=None):
    return subprocess.run(
        ['bash', '-c', 'source "$1"; shift; ' + body, 'test', str(INSTALLER), *args],
        text=True, capture_output=True, timeout=20, env=env,
    )


class Panel(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, obj, status=200, cookie=None):
        payload = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        if cookie:
            self.send_header('Set-Cookie', cookie + '; Path=' + PANEL_PATH)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.server.calls.append(('GET', self.path))
        if self.path == PANEL_PATH + 'csrf-token':
            self.reply({'success': True, 'obj': 'test-csrf'}, cookie='session=csrf')
        elif self.path == PANEL_PATH + 'panel/api/server/status':
            ok = self.headers.get('Cookie') == 'session=authenticated'
            self.reply({'success': ok}, status=200 if ok else 401)
        else:
            self.reply({'success': False}, status=404)

    def do_POST(self):
        self.server.calls.append(('POST', self.path))
        data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if self.path == PANEL_PATH + 'login':
            if self.server.mode == 'redirect':
                self.send_response(307)
                self.send_header('Location', PANEL_PATH + 'unexpected')
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            ok = (self.server.mode != 'reject'
                  and data == {'username': 'tester', 'password': PASSWORD}
                  and self.headers.get('Cookie') == 'session=csrf'
                  and self.headers.get('X-CSRF-Token') == 'test-csrf')
            cookie = 'session=authenticated' if ok and self.server.mode != 'no-session' else None
            self.reply({'success': ok}, cookie=cookie)
        elif self.path == PANEL_PATH + 'logout':
            self.reply({'success': True}, cookie='session=; Max-Age=0')
        else:
            self.reply({'success': False}, status=404)


class InstallerTests(unittest.TestCase):
    def test_username_validation(self):
        good = ['tester', 'A', '9', 'User.Name_1+ops@example-test', 'a' * 64]
        bad = ['', 'a' * 65, ' tester', 'tester ', 'тестер', '\udcd1tester',
               'te\nster', 'te\tster', 'te\x1bster', '.tester', '-tester', 'test/name']
        for value in good + bad:
            with self.subTest(value=repr(value)):
                result = bash('valid_panel_username "$1"', value)
                self.assertEqual(result.returncode == 0, value in good)

    def test_prompt_rejects_corrupt_input_and_preserves_case(self):
        result = bash("prompt_panel_username xuser <<< $'\\xD1tester\\nTester'; "
                      '[[ "$xuser" == Tester ]]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Введите заново', result.stdout)

    def run_gate(self, mode='ok', stored=b'tester'):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Panel)
        server.mode = mode
        server.calls = []
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                db = Path(tmp) / 'x-ui.db'
                conn = sqlite3.connect(db)
                conn.execute('CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT)')
                conn.execute('INSERT INTO users VALUES(1, CAST(? AS TEXT))', (stored,))
                conn.commit()
                conn.close()
                before = db.read_bytes()
                env = dict(os.environ, TEST_PANEL_PASSWORD=PASSWORD,
                           http_proxy='http://127.0.0.1:1', no_proxy='')
                result = bash(
                    'XUI_DB="$1"; xui_credentials_gate "$2" "$3" tester "$TEST_PANEL_PASSWORD"',
                    str(db), str(server.server_port), PANEL_PATH, env=env,
                )
                self.assertEqual(before, db.read_bytes(), 'gate must not change the DB')
                self.assertNotIn(PASSWORD, result.stdout + result.stderr)
                self.assertNotIn('test-csrf', result.stdout + result.stderr)
                return result, server.calls
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_login_with_csrf_cookie_and_session_verification(self):
        result, calls = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ('GET', PANEL_PATH + 'csrf-token'),
            ('POST', PANEL_PATH + 'login'),
            ('GET', PANEL_PATH + 'panel/api/server/status'),
            ('POST', PANEL_PATH + 'logout'),
        ])

    def test_invalid_utf8_in_database_is_rejected_before_http(self):
        result, calls = self.run_gate(stored=b'\xd1tester')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertIn('логина в БД', result.stderr)

    def test_wrong_password_is_not_retried(self):
        result, calls = self.run_gate(mode='reject')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sum(method == 'POST' for method, _ in calls), 1)

    def test_success_without_authenticated_session_is_rejected(self):
        result, calls = self.run_gate(mode='no-session')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('доступ по сессии', result.stderr)
        self.assertEqual(calls[-1], ('POST', PANEL_PATH + 'logout'))

    def test_redirect_does_not_forward_credentials(self):
        result, calls = self.run_gate(mode='redirect')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(path.endswith('unexpected') for _, path in calls))

    def test_credentials_failure_aborts_stack_before_client_creation(self):
        result = bash('''
          install_3xui_version(){ return 0; }
          info(){ :; }
          xui_credentials_gate(){ return 1; }
          api_token(){ echo UNEXPECTED_TOKEN_CALL >&2; return 1; }
          create_inbound(){ echo UNEXPECTED_INBOUND_CALL >&2; return 1; }
          if install_xui_stack v3.8.0 23456 dashboard-example /dashboard-example/ tester test example uuid client upstream; then
            exit 1
          fi
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
