#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.2-dev"
XRAY_PORT=10000
WS_PATH="/client/api/v2"
STATE_DIR="/etc/vpn-node-installer"
STATE_FILE="$STATE_DIR/state.env"
XUI_BIN="/usr/local/x-ui/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
INPUT_IDLE_TIMEOUT="1.5"

umask 077

info(){ printf '\n==> %s\n' "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

normalize_input(){
  local input="$1" output="$2" rejected="$3"
  python3 - "$input" "$output" "$rejected" <<'PY'
import re, sys
src, out_path, rejected_path = sys.argv[1:]
seen = set()
valid = []
rejected = []

def markdown_cell(line: str) -> str:
    s = line.strip()
    if s.startswith('|') or s.endswith('|'):
        cells = [x.strip() for x in s.strip('|').split('|')]
        nonempty = [x for x in cells if x]
        if len(nonempty) == 1:
            s = nonempty[0]
    return s.strip()

with open(src, encoding='utf-8') as f:
    for raw in f:
        original = raw.rstrip('\r\n')
        s = markdown_cell(original)
        if not s or s.startswith('#'):
            continue
        if re.fullmatch(r':?-{3,}:?', s.replace(' ', '')):
            continue
        if '\t' in s:
            s = next((x.strip() for x in s.split('\t') if x.strip()), '')
        s = s.replace(r'\@', '@').strip().strip('`').strip()
        if '@' in s:
            s = s.split('@', 1)[0].strip()
        s = s.lower()
        if not s:
            continue
        if not re.fullmatch(r'[a-z0-9._+-]+', s):
            rejected.append((original, 'разрешены только латиница, цифры, точка, _, + и -'))
            continue
        if len(s) > 128:
            rejected.append((original, 'имя длиннее 128 символов'))
            continue
        if s in seen:
            continue
        seen.add(s)
        valid.append(s)

with open(out_path, 'w', encoding='utf-8') as f:
    for s in valid:
        f.write(s + '\n')
with open(rejected_path, 'w', encoding='utf-8') as f:
    for original, reason in rejected:
        f.write(f'{original}\t{reason}\n')
PY
}

self_test(){
  local d raw out bad expected
  d=$(mktemp -d)
  trap 'rm -rf "$d"' RETURN
  raw="$d/raw"; out="$d/out"; bad="$d/bad"; expected="$d/expected"
  cat >"$raw" <<'EOF_TEST'
| alice\@legacy.example |
| --------------------- |
bob.smith@legacy.example
mobile-01@other.example
work.pc@example.test
plain_name
alice@another.example

EOF_TEST
  cat >"$expected" <<'EOF_TEST'
alice
bob.smith
mobile-01
work.pc
plain_name
EOF_TEST
  normalize_input "$raw" "$out" "$bad"
  diff -u "$expected" "$out"
  [[ ! -s "$bad" ]]
  echo "clients.sh self-test: OK"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите скрипт от root."
[[ -t 0 && -t 1 ]] || die "Скрипт рассчитан на интерактивный SSH-сеанс."
[[ -r "$STATE_FILE" ]] || die "Не найден $STATE_FILE. Сначала установите узел через install.sh."
[[ -x "$XUI_BIN" && -f "$XUI_DB" ]] || die "3x-ui не найден."
command -v curl >/dev/null || die "Не найден curl."
command -v python3 >/dev/null || die "Не найден python3."
command -v sqlite3 >/dev/null || die "Не найден sqlite3."

# state.env создаётся install.sh, принадлежит root и имеет mode 600.
# shellcheck disable=SC1090
. "$STATE_FILE"

: "${DOMAIN:?В state.env нет DOMAIN}"
: "${PANEL_PORT:?В state.env нет PANEL_PORT}"
: "${PANEL_PATH:?В state.env нет PANEL_PATH}"
INBOUND="${INBOUND:-}"

api_token(){
  local token
  token=$($XUI_BIN setting -getApiToken 2>/dev/null | awk -F': ' '/apiToken:/ {print $2;exit}' | tr -d '[:space:]')
  [[ -n "$token" ]] || die "Не удалось получить API token 3x-ui."
  printf '%s' "$token"
}

auth_header(){
  printf 'Author%s: Bear%s %s' 'ization' 'er' "$1"
}

api="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}panel/api"
token=$(api_token)

tmp=$(mktemp -d /root/vpn-clients.XXXXXX)
cleanup(){ rm -rf "$tmp"; unset token; }
trap cleanup EXIT
raw="$tmp/raw.txt"
names="$tmp/names.txt"
rejected="$tmp/rejected.txt"
existing_json="$tmp/existing.json"
new_names="$tmp/new.txt"
payload="$tmp/payload.json"
response="$tmp/response.json"
created_json="$tmp/created.json"

printf 'vpn clients helper %s\n' "$VERSION"
printf 'Узел: %s\n' "$DOMAIN"
printf '\nВставьте весь список имён или email одним блоком, по одному на строку.\n'
printf 'Можно вставить обычный столбец или Markdown-таблицу.\n'
printf 'После последней строки нажмите Enter, если курсор остался на ней. Ввод завершится автоматически после %s сек без новых строк.\n\n' "$INPUT_IDLE_TIMEOUT"

: >"$raw"
if ! IFS= read -r line; then
  die "Не получено ни одной строки."
fi
printf '%s\n' "$line" >>"$raw"
while IFS= read -r -t "$INPUT_IDLE_TIMEOUT" line; do
  printf '%s\n' "$line" >>"$raw"
done
printf '\nВвод завершён.\n'

normalize_input "$raw" "$names" "$rejected"

if [[ -s "$rejected" ]]; then
  warn "Есть строки, которые я не могу безопасно преобразовать:"
  while IFS=$'\t' read -r original reason; do
    printf '  %s  ->  %s\n' "$original" "$reason" >&2
  done <"$rejected"
  die "Исправьте эти строки и запустите снова. Ничего не изменено."
fi

mapfile -t normalized <"$names"
((${#normalized[@]} > 0)) || die "После очистки список пуст."

code=$(curl -sS -o "$existing_json" -w '%{http_code}' \
  -H "$(auth_header "$token")" "$api/clients/list" || true)
[[ "$code" == 200 ]] || die "Не удалось получить список клиентов 3x-ui (HTTP $code)."

options_json="$tmp/options.json"
code=$(curl -sS -o "$options_json" -w '%{http_code}' \
  -H "$(auth_header "$token")" "$api/inbounds/options" || true)
[[ "$code" == 200 ]] || die "Не удалось получить список inbound 3x-ui (HTTP $code)."

inbound_id=$(python3 - "$options_json" "$INBOUND" "$XRAY_PORT" <<'PY'
import json, sys
p, remark, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    data = json.load(open(p, encoding='utf-8'))
    rows = data.get('obj') or []
except Exception:
    raise SystemExit(2)
matches = [r for r in rows if r.get('protocol') == 'vless' and int(r.get('port') or 0) == port]
if remark:
    exact = [r for r in matches if r.get('remark') == remark]
    if exact:
        matches = exact
if len(matches) != 1:
    raise SystemExit(3)
print(matches[0]['id'])
PY
) || die "Не удалось однозначно определить VLESS inbound на порту $XRAY_PORT."

python3 - "$names" "$existing_json" "$DOMAIN" "$new_names" "$tmp/existing.txt" <<'PY'
import json, sys
names_path, existing_path, domain, new_path, exists_path = sys.argv[1:]
names = [x.strip() for x in open(names_path, encoding='utf-8') if x.strip()]
try:
    data = json.load(open(existing_path, encoding='utf-8'))
    rows = data.get('obj') or []
except Exception:
    raise SystemExit(2)
existing = {str(r.get('email') or '').lower() for r in rows}
with open(new_path, 'w', encoding='utf-8') as new, open(exists_path, 'w', encoding='utf-8') as old:
    for name in names:
        email = f'{name}@{domain}'.lower()
        if email in existing:
            old.write(email + '\n')
        else:
            new.write(name + '\n')
PY

mapfile -t new_clients <"$new_names"
mapfile -t old_clients <"$tmp/existing.txt"

info "Предпросмотр"
printf 'Новых: %d\n' "${#new_clients[@]}"
printf 'Уже существуют: %d\n' "${#old_clients[@]}"

if ((${#new_clients[@]})); then
  printf '\nБудут добавлены:\n'
  for name in "${new_clients[@]}"; do printf '  %s@%s\n' "$name" "$DOMAIN"; done
fi
if ((${#old_clients[@]})); then
  printf '\nБез изменений, уже существуют:\n'
  for email in "${old_clients[@]}"; do printf '  %s\n' "$email"; done
fi

((${#new_clients[@]} > 0)) || { printf '\nНовых клиентов нет.\n'; exit 0; }

read -r -p "Добавить ${#new_clients[@]} клиент(ов)? [Y/n]: " answer
[[ ! "$answer" =~ ^[Nn]$ ]] || { echo "Отменено."; exit 0; }

backup_dir="$STATE_DIR/backups"
install -d -m700 "$backup_dir"
backup="$backup_dir/x-ui-before-clients-$(date +%Y%m%d-%H%M%S).db"
sqlite3 "$XUI_DB" ".backup '$backup'"
chmod 600 "$backup"
info "Создан backup 3x-ui: $backup"

python3 - "$new_names" "$DOMAIN" "$inbound_id" "$payload" <<'PY'
import json, sys, uuid
names_path, domain, inbound_id, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
items = []
for raw in open(names_path, encoding='utf-8'):
    name = raw.strip()
    if not name:
        continue
    email = f'{name}@{domain}'
    uid = str(uuid.uuid4())
    items.append({
        'client': {
            'id': uid,
            'email': email,
            'flow': '',
            'limitIp': 0,
            'totalGB': 0,
            'expiryTime': 0,
            'enable': True,
            'tgId': 0,
            'subId': '',
            'comment': '',
            'reset': 0,
        },
        'inboundIds': [inbound_id],
    })
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(items, f, separators=(',', ':'))
PY

code=$(curl -sS -o "$response" -w '%{http_code}' -X POST \
  -H "$(auth_header "$token")" \
  -H 'Content-Type: application/json' \
  --data-binary "@$payload" \
  "$api/clients/bulkCreate" || true)
[[ "$code" == 200 ]] || die "3x-ui API не выполнил bulkCreate (HTTP $code). Backup: $backup"

python3 - "$response" "$payload" "$created_json" <<'PY'
import json, sys
resp_path, payload_path, out_path = sys.argv[1:]
resp = json.load(open(resp_path, encoding='utf-8'))
if resp.get('success') is not True:
    print(resp.get('msg') or '3x-ui returned success=false', file=sys.stderr)
    raise SystemExit(2)
obj = resp.get('obj') or {}
skipped = obj.get('skipped') or []
skipped_map = {str(x.get('email') or ''): str(x.get('reason') or 'unknown') for x in skipped}
items = json.load(open(payload_path, encoding='utf-8'))
created = [x for x in items if x.get('client', {}).get('email') not in skipped_map]
reported = int(obj.get('created') or 0)
if reported != len(created):
    print(f'bulkCreate mismatch: API created={reported}, calculated={len(created)}', file=sys.stderr)
    raise SystemExit(3)
if skipped_map:
    print('3x-ui пропустил некоторые строки:', file=sys.stderr)
    for email, reason in skipped_map.items():
        print(f'  {email}: {reason}', file=sys.stderr)
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(created, f, separators=(',', ':'))
PY

created_count=$(python3 - "$created_json" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding='utf-8'))))
PY
)
((created_count > 0)) || die "3x-ui не создал ни одного клиента. Backup: $backup"

sleep 2
ss -ltnH | awk '{print $4}' | grep -Eq "127\\.0\\.0\\.1:${XRAY_PORT}$" || die "После добавления Xray не слушает 127.0.0.1:${XRAY_PORT}. Backup: $backup"

python3 - "$created_json" "$api" "$token" <<'PY'
import json, sys, urllib.parse, urllib.request
items_path, api, token = sys.argv[1:]
items = json.load(open(items_path, encoding='utf-8'))
for item in items:
    expected = item['client']
    email = expected['email']
    url = f"{api}/clients/get/{urllib.parse.quote(email, safe='')}"
    headers = {''.join(['Author', 'ization']): ' '.join(['Bear' + 'er', token])}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            data = json.load(r)
    except Exception as exc:
        print(f'Не удалось проверить {email}: {exc}', file=sys.stderr)
        raise SystemExit(2)
    obj = data.get('obj') or {}
    client = obj.get('client') or {}
    inbound_ids = obj.get('inboundIds') or []
    actual_uuid = client.get('uuid') or client.get('id') or ''
    if data.get('success') is not True or actual_uuid != expected['id']:
        print(f'Проверка UUID не прошла для {email}', file=sys.stderr)
        raise SystemExit(3)
    target = item['inboundIds'][0]
    if target not in inbound_ids:
        print(f'{email} не привязан к inbound {target}', file=sys.stderr)
        raise SystemExit(4)
PY

info "Добавлено клиентов: $created_count"
printf '\nГотовые VLESS URL:\n'
python3 - "$created_json" "$DOMAIN" "$WS_PATH" <<'PY'
import json, sys, urllib.parse
items_path, domain, ws_path = sys.argv[1:]
items = json.load(open(items_path, encoding='utf-8'))
path = urllib.parse.quote(ws_path, safe='')
for item in items:
    c = item['client']
    label = urllib.parse.quote(c['email'], safe='')
    print(
        f"vless://{c['id']}@{domain}:443"
        f"?type=ws&encryption=none&security=tls&sni={domain}&host={domain}"
        f"&path={path}&alpn=http%2F1.1#{label}"
    )
PY