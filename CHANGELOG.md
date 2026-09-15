# Changelog

## 0.1.2-dev — 2026-09-15

Client-creation workflow improvements.

- `clients.sh` no longer requires a `.` sentinel line.
- Client input is pasted as one block and ends automatically after 1.5 seconds without another completed line; if the last pasted row has no trailing newline, one `Enter` commits it.
- `install.sh` now installs the helper as `/usr/local/sbin/vpn-clients` from this repository after a successful node install.
- The installer offers to launch bulk client creation immediately; declining leaves the completed VPN installation untouched and the helper remains available for later use.
- Added CI invariants for the new idle-input mode and post-install helper handoff.
- Documented the official upstream 3x-ui repository (`MHSanaei/3x-ui`) and recorded **3x-ui v3.8.0** as the project's known-good tested baseline from the first successful clean-VPS deployment.

## 0.1.1-dev — 2026-09-15

Post-test fixes after the first successful end-to-end VPS deployment.

- Initial client name changed from `default` to `default@<full-domain>`.
- Installer-generated UUID v4 remains the source of truth for the client ID.
- UFW now detects and preserves the active SSH server port instead of assuming port 22.
- WebSocket audit still requires HTTP 101 but suppresses the expected curl timeout after the protocol upgrade.
- Added an explicit `/favicon.svg` route and favicon link for the neutral service page.
- nginx injects the same favicon link into proxied 3x-ui HTML.
- Added GitHub Actions validation for Bash syntax, ShellCheck errors and required installer invariants.
- Added `clients.sh`: interactive bulk client creation from pasted names/email addresses, with normalization, duplicate skipping, backup, verification and one VLESS URL per output line.
- Added a separate GitHub Actions validation workflow for `clients.sh`.

## 0.1.0-dev — 2026-09-15

Initial development version. This version completed the first clean-VPS end-to-end test successfully, including a real VLESS client connection.

- Ubuntu 24.04 x64 preflight.
- Immediate/persistent IPv6 disable.
- Telegram connectivity preflight.
- DNS readiness with authoritative NS + Cloudflare/Google/Quad9.
- nginx + Let's Encrypt webroot.
- latest official 3x-ui unattended install.
- localhost-only 3x-ui panel.
- subscription server disabled.
- VLESS WebSocket inbound on localhost:10000.
- fixed `/client/api/v2` WS path.
- installer-generated UUID v4 for the initial client.
- `trustedXForwardedFor` support.
- nginx Basic Auth (`admin`).
- UFW SSH/80/443 baseline.
- neutral embedded favicon and service endpoint.
- health/version endpoints.
- safe re-run guard and diagnostics.
- final WebSocket/certificate/renewal/Telegram checks.
