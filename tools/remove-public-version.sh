#!/usr/bin/env bash
# Remove the legacy unauthenticated /version location from the ACTIVE nginx site.
# Detect active files with nginx -T, not from fixed paths or old installer state.
# Read-only detection, backup, atomic edit, nginx -t, reload, automatic rollback.
# Never touches Xray, UFW, DNS, or any other nginx location.
set -Eeuo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo bash tools/remove-public-version.sh" >&2
  exit 1
fi

if ! nginx -t >/dev/null 2>&1; then
  echo "Existing nginx configuration fails validation. Not changing anything." >&2
  exit 1
fi

if ! result="$(python3 - <<'PY'
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile

res = subprocess.run(["nginx", "-T"], capture_output=True, text=True)
if res.returncode:
    sys.exit("nginx -T failed; no change")

loaded = {}
current = None
for line in res.stdout.splitlines():
    m = re.match(r"^# configuration file (.+):$", line)
    if m:
        current = m.group(1)
        continue
    if current and re.match(r"^\s*location\s*=\s*/version\s*\{", line):
        loaded.setdefault(current, []).append(line)

if not loaded:
    print("NOTHING")
    sys.exit(0)

# A single managed config is expected. Do not risk deleting other locations.
paths = {Path(name).resolve() for name in loaded}
if len(paths) != 1:
    sys.exit("Multiple active files contain /version. Manual review required: "
             + ", ".join(sorted(str(p) for p in paths)))

path = next(iter(paths))
nginx_dir = Path("/etc/nginx").resolve()
if not path.is_relative_to(nginx_dir) or not path.is_file():
    sys.exit("Unexpected configuration file path: " + str(path))

source = path.read_text(encoding="utf-8")
lines = source.splitlines(keepends=True)
matches = [line for line in lines
           if re.match(r"^\s*location\s*=\s*/version\s*\{", line)]
if len(matches) != 1:
    sys.exit("Expected exactly one /version location in " + str(path))

line = matches[0]
if not (re.fullmatch(r"\s*location\s*=\s*/version\s*\{[^\r\n]*\}\s*", line)
        and "vpn-node-installer" in line
        and "return 200" in line):
    sys.exit("The /version location has an unexpected form; no change.")

updated = source.replace(line, "", 1)
backup_dir = Path("/root/vpn-node-backups")
backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
backup_dir.chmod(0o700)
stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
digest = hashlib.sha256(str(path).encode()).hexdigest()[:10]
backup = backup_dir / (path.name + "." + digest + "." + stamp + ".bak")
if backup.exists():
    sys.exit("Backup collision: " + str(backup))
# Backup lives in a root-only directory; preserve original owner/mode for rollback.
shutil.copy2(path, backup)

meta = path.stat()
fd, temp_name = tempfile.mkstemp(prefix=".vpn-node-nginx-", dir=path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(updated)
    os.chmod(temp_name, stat.S_IMODE(meta.st_mode))
    os.chown(temp_name, meta.st_uid, meta.st_gid)
    os.replace(temp_name, path)
finally:
    if os.path.exists(temp_name):
        os.unlink(temp_name)

# Output is parsed by the outer shell only after successful atomic edit.
print(str(path) + "|" + str(backup))
PY
)"; then
  echo "Unable to identify or edit active /version; no nginx reload." >&2
  exit 1
fi

if [[ "$result" == "NOTHING" ]]; then
  echo "OK: no /version location in active nginx configuration."
  exit 0
fi

IFS='|' read -r conf backup <<< "$result"
if [[ -z "$conf" || -z "$backup" || ! -f "$backup" ]]; then
  echo "Unexpected cleanup output; inspect nginx before proceeding." >&2
  exit 1
fi

if ! nginx -t; then
  cp -p -- "$backup" "$conf"
  nginx -t || true
  echo "ERROR: validation failed; original nginx config restored. No reload." >&2
  exit 1
fi

if ! systemctl reload nginx; then
  cp -p -- "$backup" "$conf"
  systemctl reload nginx || true
  echo "ERROR: reload failed; original config restored." >&2
  exit 1
fi

if nginx -T 2>/dev/null | grep -Eq '^[[:space:]]*location[[:space:]]*=[[:space:]]*/version[[:space:]]*\{'; then
  echo "WARNING: an active /version location still exists; inspect manually." >&2
  exit 1
fi

echo "OK: /version removed from active nginx config: $conf"
echo "Backup: $backup"
echo "Nginx validated and reloaded. No change to Xray, UFW or other routes."
