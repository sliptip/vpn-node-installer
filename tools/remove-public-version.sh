#!/usr/bin/env bash
# Remove an unsafe public /version location left by older vpn-node-installer builds.
# Idempotent. Touches only the installer-managed nginx site, not Xray or UFW.
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash tools/remove-public-version.sh" >&2
  exit 1
fi

conf="/etc/nginx/sites-available/vpn-node.conf"
if [[ ! -f "$conf" ]]; then
  echo "No installer-managed nginx site at $conf; nothing changed."
  exit 0
fi

if ! grep -Eq '^[[:space:]]*location[[:space:]]*=[[:space:]]*/version[[:space:]]*\{' "$conf"; then
  echo "No public /version location in $conf; nothing changed."
  exit 0
fi

backup="$conf.before-remove-public-version.$(date -u +%Y%m%dT%H%M%SZ).bak"
if [[ -e "$backup" ]]; then
  echo "Backup already exists: $backup" >&2
  exit 1
fi
cp -p -- "$conf" "$backup"

if ! python3 - "$conf" <<'PY'
from pathlib import Path
import os
import re
import stat
import sys
import tempfile

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
lines = source.splitlines(keepends=True)
matches = [line for line in lines if re.match(r"^\s*location\s*=\s*/version\s*\{", line)]
if len(matches) != 1 or "vpn-node-installer" not in matches[0] or "return 200" not in matches[0]:
    sys.exit("Unexpected /version location; no change. Inspect nginx configuration manually.")
updated = source.replace(matches[0], "", 1)
mode = stat.S_IMODE(path.stat().st_mode)
fd, temporary = tempfile.mkstemp(prefix=".vpn-node-nginx-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(updated)
    os.chmod(temporary, mode)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
then
  cp -p -- "$backup" "$conf"
  echo "Edit failed. Original nginx site restored." >&2
  exit 1
fi

if ! nginx -t; then
  cp -p -- "$backup" "$conf"
  nginx -t || true
  echo "Nginx validation failed. Original configuration restored; nginx not reloaded." >&2
  exit 1
fi

if ! systemctl reload nginx; then
  cp -p -- "$backup" "$conf"
  systemctl reload nginx || true
  echo "Nginx reload failed. Original configuration restored." >&2
  exit 1
fi

echo "Removed public /version location, validated nginx and reloaded it."
echo "Backup: $backup"
echo "Verify: curl -sS -o /dev/null -w '%{http_code}\n' https://YOUR-DOMAIN/version"
