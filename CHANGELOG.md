# Changelog

## 0.1.0-dev — 2026-09-15

Initial development version.

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
- installer-generated UUID v4 for `default` client.
- `trustedXForwardedFor` support.
- nginx Basic Auth (`admin`).
- UFW 22/80/443.
- neutral embedded favicon and service endpoint.
- health/version endpoints.
- safe re-run guard and diagnostics.
- final WebSocket/certificate/renewal/Telegram checks.
