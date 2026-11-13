#!/usr/bin/env python3
"""Read-only audit of VPN public HTTP fingerprints and listening sockets.

Checks local nginx with the real public domain/SNI; does not test external
reachability, DPI fingerprints or client-side DNS/WebRTC leaks. No config writes.
"""
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONFIG = Path("/etc/nginx/sites-available/vpn-node.conf")
STATE = Path("/etc/vpn-node-installer/state.env")
SENSITIVE = re.compile(r"vpn[-_ ]?node|vpn[-_ ]?installer|3x[-_ ]?ui|x[-_ ]?ui|xray|vless|vmess|reality", re.I)
DOMAIN_RE = re.compile(r"^(?=.{4,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$", re.I)


def run(args, timeout=15):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def state_values():
    result = {}
    if STATE.exists():
        for line in STATE.read_text(encoding="utf-8", errors="replace").splitlines():
            match = re.match(r"^(DOMAIN|PANEL_PATH)=(.*)$", line)
            if match:
                result[match.group(1)] = match.group(2).strip().strip("\"'")
    return result


def cert_domains(site):
    """Read TLS SANs. This catches servers whose original DNS name is stale."""
    match = re.search(r"^\s*ssl_certificate\s+([^;]+);", site, re.M)
    if not match or "$" in match.group(1):
        return []
    result = run(["openssl", "x509", "-in", match.group(1).strip(),
                  "-noout", "-ext", "subjectAltName"], timeout=8)
    if result is None or result.returncode:
        return []
    return [name for name in re.findall(r"DNS:([A-Za-z0-9.-]+)", result.stdout)
            if DOMAIN_RE.fullmatch(name)]


def discover_site():
    site = CONFIG.read_text(encoding="utf-8", errors="replace") if CONFIG.exists() else ""
    state = state_values()
    domain = os.environ.get("VPN_AUDIT_DOMAIN", "").strip()
    if not domain:
        for entry in re.findall(r"\bserver_name\s+([^;]+);", site):
            candidates = [name for name in entry.split() if DOMAIN_RE.fullmatch(name)]
            if candidates:
                domain = candidates[0]
                break
    if not domain:
        domain = state.get("DOMAIN", "")
    # A renamed host may still have an obsolete server_name/state domain.
    # The active certificate's SAN is more reliable for choosing HTTPS SNI.
    sans = cert_domains(site)
    if not os.environ.get("VPN_AUDIT_DOMAIN") and sans and domain not in sans:
        print("REVIEW configured domain", repr(domain),
              "differs from TLS certificate; selecting", sans[0])
        domain = sans[0]
    if not DOMAIN_RE.fullmatch(domain):
        raise ValueError("Could not discover domain. Set VPN_AUDIT_DOMAIN=example.org")
    panel = state.get("PANEL_PATH", "")
    active = re.findall(r"location\s+\^~\s+(/dashboard-[A-Za-z0-9_-]+/)", site)
    if active:
        panel = active[0]
    if panel and not re.fullmatch(r"/[A-Za-z0-9/_-]{1,200}", panel):
        panel = ""
    return domain, panel, site


def request(domain, path, folder):
    headers = str(Path(folder) / "headers")
    body = str(Path(folder) / "body")
    args = ["curl", "-sS", "--noproxy", "*", "--connect-timeout", "3",
            "--max-time", "7", "--resolve", domain + ":443:127.0.0.1",
            "--dump-header", headers, "--output", body,
            "--write-out", "%{http_code}", "https://" + domain + path]
    result = run(args, 11)
    if result is None or result.returncode != 0:
        err = "not executed" if result is None else (
            result.stderr.strip().splitlines()[-1][:160]
            if result.stderr.strip() else "curl exit " + str(result.returncode))
        return None, "", "", err
    try:
        return (int(result.stdout.strip()),
                Path(headers).read_text(encoding="utf-8", errors="replace"),
                Path(body).read_text(encoding="utf-8", errors="replace")[:100000], "")
    except (ValueError, OSError) as error:
        return None, "", "", str(error)


def ports():
    """Report TCP listeners and UDP sockets separately; UDP ephemeral != open service."""
    output = run(["ss", "-H", "-lntup"])
    if not output or output.returncode:
        print("INFO  Listening socket audit not available")
        return
    try:
        low, high = map(int, Path("/proc/sys/net/ipv4/ip_local_port_range")
                        .read_text().split()[:2])
    except (OSError, ValueError):
        low, high = 32768, 60999

    tcp_public, udp_public, internal = set(), set(), set()
    for line in output.stdout.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        proto, address = parts[0], parts[4]
        found = re.search(r":(\d+)$", address)
        if not found:
            continue
        port = int(found.group(1))
        ip = address[:found.start()].strip("[]")
        is_public = ip in ("*", "0.0.0.0", "::")
        if not is_public:
            try:
                parsed = ipaddress.ip_address(ip.split("%", 1)[0])
                if parsed.is_loopback:
                    continue
                is_public = not parsed.is_private
            except ValueError:
                is_public = False
        if not is_public:
            internal.add((proto, address, port))
        elif proto.startswith("tcp"):
            tcp_public.add((proto, address, port))
        elif proto.startswith("udp"):
            udp_public.add((proto, address, port))

    print("TCP public/wildcard listeners:",
          ", ".join(sorted({p + " " + a for p, a, _ in tcp_public})) or "none")
    unexpected_tcp = sorted({p + "/" + str(port) for p, _, port in tcp_public
                             if port not in (22, 80, 443)})
    if unexpected_tcp:
        print("REVIEW Unexpected TCP public/wildcard listeners:",
              ", ".join(unexpected_tcp))
    else:
        print("OK    No unexpected public TCP listeners (custom SSH may differ)")

    udp_standard = sorted({a for p, a, port in udp_public if port == 443})
    udp_dynamic = {(p, a, port) for p, a, port in udp_public
                   if low <= port <= high}
    udp_other = sorted({p + "/" + str(port) for p, _, port in udp_public
                        if port != 443 and not low <= port <= high})
    print("UDP/443 sockets:", ", ".join(udp_standard) or "none")
    if udp_dynamic:
        print(f"INFO  {len(udp_dynamic)} UDP sockets in OS ephemeral range "
              f"{low}-{high}; may be outbound traffic, not proven exposed listeners")
    if udp_other:
        print("REVIEW Other public/wildcard UDP sockets:", ", ".join(udp_other))
    if internal:
        print("Private-interface sockets:",
              ", ".join(sorted({p + " " + a for p, a, _ in internal})))
    ufw = run(["ufw", "status"])
    if ufw and ufw.returncode == 0:
        first = ufw.stdout.splitlines()
        print("UFW:", first[0] if first else "unknown")
        if not first or "Status: active" not in first[0]:
            print("REVIEW UFW inactive; check provider firewall")
    else:
        print("INFO  UFW unavailable; check other firewall rules")


def main():
    print("=== READ-ONLY VPN PUBLIC SURFACE AUDIT ===")
    host = run(["hostname"])
    print("Host:", host.stdout.strip() if host else "?")
    try:
        domain, panel, site = discover_site()
    except ValueError as error:
        print("ERROR", error)
        return 2
    print("Domain:", domain)
    print("Local HTTPS test: 127.0.0.1 with correct SNI and certificate validation")

    ngtest = run(["nginx", "-t"])
    print("OK   " if ngtest and ngtest.returncode == 0 else "REVIEW", "nginx -t")
    active = run(["nginx", "-T"], timeout=20)
    conf = active.stdout if active and active.returncode == 0 else site
    version_in_nginx = bool(re.search(r"location\s*=\s*/version\s*\{", conf))
    if version_in_nginx:
        print("ALERT /version location in nginx configuration")
    else:
        print("OK    No explicit /version location")
    if re.search(r"return\s+200[^;\n]*(?:vpn[-_ ]?node|vpn[-_ ]?installer|3x[-_ ]?ui|xray)", conf, re.I):
        print("ALERT nginx response discloses VPN software")
    else:
        print("OK    No obvious branded nginx 200 response")
    if panel and site:
        start = site.find("location ^~ " + panel)
        if start >= 0 and "auth_basic" in site[start:start + 350]:
            print("OK    Panel location has Basic Auth")
        else:
            print("REVIEW Panel Basic Auth not verified in config")

    print("\n--- HTTP without authentication ---")
    issues = 1 if version_in_nginx else 0
    targets = ["/", "/version", "/health", "/api/", "/metrics", "/debug",
               "/.env", "/server-status", "/swagger/", "/x-ui/", "/robots.txt"]
    if panel:
        targets.append(panel)
    with tempfile.TemporaryDirectory(prefix="vpn-public-audit-") as folder:
        for path in targets:
            code, headers, body, error = request(domain, path, folder)
            if error:
                print(f"REVIEW {path:<20} unavailable: {error}")
                issues += 1
                continue
            state, why = "OK   ", ""
            if path == "/version" and version_in_nginx:
                state, why = "ALERT", "nginx config has /version; HTTP result may be from stale SNI"
            elif path == "/version" and code not in (404, 410):
                state, why = "ALERT", "version route should return 404"
            elif path == "/health":
                try:
                    neutral = json.loads(body) == {"status": "ok"}
                except (ValueError, TypeError):
                    neutral = False
                if code != 200 or not neutral:
                    state, why = "REVIEW", "unexpected health response"
            elif panel and path == panel and code != 401:
                state, why = "ALERT", "panel must require Basic Auth (401)"
            elif path == "/" and SENSITIVE.search(body):
                state, why = "ALERT", "root page mentions VPN stack"
            elif path not in ("/", "/robots.txt", "/health", "/version"):
                if code == 200:
                    state, why = "ALERT", "unexpected public endpoint"
                elif code in (301, 302, 307, 308):
                    state, why = "REVIEW", "redirect on diagnostic path"
            if SENSITIVE.search(body) and path != "/health":
                state, why = "ALERT", "response includes VPN identifiers"
            if re.search(r"^Server:\s*[^\r\n]*/\d", headers, re.I | re.M):
                state, why = "REVIEW", "HTTP Server header exposes version"
            if re.search(r"^X-Powered-By:", headers, re.I | re.M):
                state, why = "REVIEW", "X-Powered-By header"
            if state != "OK   ":
                issues += 1
            print(f"{state} {path:<20} HTTP {code:<3} {why}")

    print("\n--- Local listening sockets ---")
    ports()
    print("\nLIMITATION: Local HTTPS audit is not external port scan or proof against DPI,")
    print("DNS/IPv6/WebRTC leaks or vulnerabilities in 3x-ui/Xray. No secrets printed.")
    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
