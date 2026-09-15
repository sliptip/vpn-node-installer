# Specification — v0.1

## Supported target

- Ubuntu 24.04 LTS x64
- clean VPS
- root interactive shell
- one public IPv4
- no IPv6 use

## Fixed values

- protocol: VLESS
- transport: WebSocket
- external port: 443
- internal Xray: `127.0.0.1:10000`
- WS path: `/client/api/v2`
- internal Xray TLS/security: `none`
- Basic Auth username: `admin`
- initial client name: `default`
- database: SQLite

## Derived values

For domain `a.b.tld`:

- domain key: `b`
- inbound remark: `b`
- panel base path: `/dashboard-b/`

The derivation intentionally means “label immediately before the TLD”, matching the current infrastructure convention. It is not a Public Suffix List implementation.

## Interactive input

1. FQDN
2. 3x-ui username
3. 3x-ui password + confirmation
4. Basic Auth password + confirmation

Passwords are read without echo and are never written to the installer log.

## Generated values

- random free panel port in `20000..60000`
- client UUID: RFC 4122 UUID v4

## IPv6 policy

IPv6 is disabled using `/etc/sysctl.d/99-vpn-node-disable-ipv6.conf`:

- `net.ipv6.conf.all.disable_ipv6=1`
- `net.ipv6.conf.default.disable_ipv6=1`
- `net.ipv6.conf.lo.disable_ipv6=1`

UFW is also configured with `IPV6=no`. DNS readiness requires an empty AAAA response.

## 3x-ui policy

- official upstream `https://github.com/MHSanaei/3x-ui`
- latest installer from upstream `main`
- SQLite
- panel internal SSL disabled (nginx terminates TLS)
- panel forcibly rebound to `127.0.0.1` immediately after upstream install
- `subEnable=false`
- upstream `/etc/x-ui/install-result.env` is removed after the API token is consumed

The initial inbound is created through the authenticated local 3x-ui API instead of hand-inserting an inbound row. This lets 3x-ui maintain its current normalized client tables and related metadata.

## WebSocket inbound

Required stream settings:

- network `ws`
- path `/client/api/v2`
- internal security `none`
- `trustedXForwardedFor: ["X-Real-IP"]`

nginx supplies `Upgrade`, `Connection: upgrade`, `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.

## DNS readiness

1. Walk up the FQDN until the authoritative DNS zone is found.
2. Every authoritative NS must return exactly the VPS IPv4 for A.
3. Authoritative AAAA must be empty.
4. Check 1.1.1.1, 8.8.8.8, 9.9.9.9 with the same rules.
5. Poll every 30 seconds for 10 minutes.
6. If authoritative DNS is correct but public cache remains stale, offer wait / try certificate / exit.
7. If authoritative DNS itself is wrong, do not offer certificate issuance.

## Public exposure

Expected public listeners:

- 22/tcp SSH
- 80/tcp nginx
- 443/tcp nginx

Expected localhost listeners include random 3x-ui panel port and 10000 Xray WS.

Forbidden public listeners: panel port, 10000, 2096.

## Re-run policy

A completed installation has `/etc/vpn-node-installer/installed` and `/etc/vpn-node-installer/state.env`.

Re-run: diagnostics or exit only. If x-ui/nginx remnants exist without our state marker, abort without overwriting anything.

## Secrets policy

Do not persist in `/var/log/vpn-node-installer.log`:

- panel password
- Basic Auth password
- API token
- UUID
- VLESS link
- private TLS key contents

The 3x-ui database and nginx htpasswd naturally contain operational credentials and remain root-protected system state.
