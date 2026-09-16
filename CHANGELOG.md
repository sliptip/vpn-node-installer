# Changelog

## 0.1.7-dev — 2026-09-16

Fresh-install credential validation and small installer fixes.

- Reject malformed/non-ASCII panel usernames before installation; preserve case and require explicit re-entry rather than silently stripping characters.
- Add a read-only byte-exact username check and a real localhost login check with CSRF/cookies before accepting a 3x-ui installation. A failed check enters the existing fresh-install fallback flow; it never resets credentials on a live node.
- Verify session-authenticated API access, refuse redirects, bypass proxy environment settings and avoid repeating rejected login attempts. Passwords, cookies and response bodies are not printed by this check.
- Move root validation ahead of log-file creation; diagnostics now show the detected SSH port rather than hard-coded port 22.
- Remove the unused `normalize_path` function and unnecessary `python3-certbot-nginx` dependency; certificate issuance remains webroot-based.
- Document the intentional removal of upstream `install-result.env` after successful setup. Its absence is not an upstream failure.
- Add offline regression tests using a temporary SQLite database and local HTTP panel stand-in.
- Client helper remains `0.1.6-dev`; known-good remains `v3.8.0`. This installer version still needs a fresh-VPS test.

## 0.1.6-dev — 2026-09-16

Bulk-client input hardening.

- Reworked pasted input collection to finish on a 1.5-second character-idle gap after the paste starts, so the final line is preserved even without a trailing newline or `Enter`.
- Single-line pastes without a trailing newline are handled by the same collector.
- Client names made only of punctuation such as `.`, `..`, `_`, `+`, or `-` are rejected before preview/mutation; at least one ASCII letter or digit is required.
- Extended `clients.sh --self-test` to cover both the no-final-newline path and punctuation-only rejection.
- `install.sh` and `clients.sh` now report `0.1.6-dev`.
## 0.1.5-dev — 2026-09-15

Known-good 3x-ui source redundancy.

- Added emergency mirror `sliptip/3x-ui` for known-good `v3.8.0` while keeping `MHSanaei/3x-ui` as the primary source.
- If a fresh-install known-good attempt from the official source fails, x-ui state from that attempt is cleaned and the exact same `v3.8.0` is retried from the mirror.
- Mirror mode redirects the tagged 3x-ui installer to the mirrored repository/release assets rather than silently falling back to the original release URL.
- The archived Linux amd64 release checksum is pinned to `236b837627520f0c4ae4134dc6a34ea5e294b69e158879795fe8cd51c5f3582c` and checked before mirror installation.
- Newer untested 3x-ui candidates continue to come only from official upstream; the mirror is a known-good emergency path, not a second latest channel.
- `install.sh` and `clients.sh` now report `0.1.5-dev`; CI includes mirror-fallback invariants.

## 0.1.4-dev — 2026-09-15

Safety and version-reporting fixes after the first live-node maintenance pass.

- Fixed OS detection so sourcing `/etc/os-release` cannot overwrite the installer's own `VERSION`; `/version`, state and logs now retain the actual installer version.
- Bulk client creation now uses a fail-safe `[y/N]` confirmation: only an explicit `y`/`Y` performs the mutation; `Enter` cancels.
- `install.sh` and `clients.sh` now report `0.1.4-dev`.
- CI keeps explicit invariants for installer-version preservation and fail-safe client confirmation.

## 0.1.3-dev — 2026-09-15

Safer 3x-ui release selection for fresh installs.

- Added explicit `XUI_KNOWN_GOOD=v3.8.0`.
- Fresh installs resolve the current upstream latest stable 3x-ui release.
- If latest equals known-good, install it directly; if a newer stable exists, offer to try it with automatic fallback or install known-good immediately. The safe default is known-good.
- If latest lookup fails, use known-good.
- Upstream installer scripts are fetched from the exact selected release tag and invoked with the same tag instead of using a floating `main` installer for the actual 3x-ui attempt.
- Added a compatibility gate covering panel localhost settings, API token, VLESS inbound creation, Xray listener, initial client readback and client/inbound API endpoints used by this project.
- A failed newer candidate is cleaned up only during the still-fresh install and retried as a clean tagged `v3.8.0` installation; no in-place downgrade of an existing database is attempted.
- Existing completed nodes are never automatically upgraded or downgraded by this mechanism.
- The accepted 3x-ui tag is stored as `XUI_VERSION` in node state and shown in the final summary.
- Extended installer CI invariants for known-good selection, tagged installation, compatibility gate and fallback cleanup.

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
