#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.2-dev"
WS_PATH="/client/api/v2"
XRAY_PORT=10000
BASIC_USER="admin"
STATE_DIR="/etc/vpn-node-installer"
STATE_FILE="$STATE_DIR/state.env"
MARKER="$STATE_DIR/installed"
LOG="/var/log/vpn-node-installer.log"
XUI_BIN="/usr/local/x-ui/x-ui"
XUI_DB="/etc/x-ui/x-ui.db"
ACME_ROOT="/var/www/letsencrypt"
WEB_ROOT="/var/www/vpn-node"
STATIC_ROOT="/var/www/vpn-node-static"
HTPASSWD="/etc/nginx/.htpasswd"
UPSTREAM_INSTALL="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
CLIENT_HELPER_URL="https://raw.githubusercontent.com/sliptip/vpn-node-installer/main/clients.sh"
CLIENT_HELPER_BIN="/usr/local/sbin/vpn-clients"

umask 077
mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 600 "$LOG"

log(){ printf '[%s] %s\n' "$(date -Is)" "$*" >>"$LOG"; }
info(){ printf '\n==> %s\n' "$*"; log "$*"; }
warn(){ printf '\n[WARN] %s\n' "$*" >&2; log "WARN: $*"; }
die(){ printf '\n[ERROR] %s\n' "$*" >&2; log "ERROR: $*"; exit 1; }
trap 'rc=$?; log "ERROR line=${BASH_LINENO[0]:-?} rc=$rc"; printf "\n[ERROR] Установка прервана. Лог: %s\n" "$LOG" >&2; exit "$rc"' ERR

need_root(){ [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запустите скрипт от root."; }
need_tty(){ [[ -t 0 && -t 1 ]] || die "Эта dev-версия рассчитана на интерактивный SSH-сеанс."; }

check_os(){
  . /etc/os-release
  [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04* ]] || die "Поддерживается только Ubuntu 24.04 LTS."
  [[ "$(uname -m)" == x86_64 ]] || die "Поддерживается только x86_64/amd64."
}

valid_domain(){ [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4(){ python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress,sys
try:
 i=ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if i.version==4 else 1)
except Exception: raise SystemExit(1)
PY
}

prompt_nonempty(){
  local __v="$1" p="$2" x=""
  while [[ -z "$x" ]]; do read -r -p "$p" x; done
  printf -v "$__v" '%s' "$x"
}

prompt_secret(){
  local __v="$1" p="$2" a b
  while true; do
    read -r -s -p "$p: " a; printf '\n'
    [[ -n "$a" ]] || { echo "Пароль пустой."; continue; }
    read -r -s -p "Повторите пароль: " b; printf '\n'
    [[ "$a" == "$b" ]] || { echo "Пароли не совпадают."; continue; }
    printf -v "$__v" '%s' "$a"; return
  done
}

domain_key(){ awk -F. '{if(NF>=2) print $(NF-1)}' <<<"$1"; }
normalize_path(){ local p="/${1#/}"; printf '%s/\n' "${p%/}"; }

free_panel_port(){
  local p
  for _ in $(seq 1 100); do
    p=$(shuf -i 20000-60000 -n1)
    [[ "$p" -eq "$XRAY_PORT" ]] && continue
    ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)${p}$" || { echo "$p"; return; }
  done
  return 1
}

uuid_v4(){
  local u; u=$(cat /proc/sys/kernel/random/uuid)
  [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] || die "Не удалось получить UUID v4."
  echo "$u"
}

public_ipv4(){
  local u ip
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4fsS --connect-timeout 5 --max-time 10 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv4 "$ip" && { echo "$ip"; return; }
  done
  return 1
}

ssh_server_port(){
  local p=""
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="${SSH_CONNECTION##* }"
  fi
  if [[ ! "$p" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
    p=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  fi
  if [[ ! "$p" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then
    p=22
  fi
  echo "$p"
}

existing_guard(){
  if [[ -f "$MARKER" ]]; then
    [[ -r "$STATE_FILE" ]] && . "$STATE_FILE"
    echo "Обнаружен уже установленный узел: ${DOMAIN:-unknown}."
    echo "1) Диагностика"
    echo "2) Выход"
    read -r -p "Выберите [1/2]: " c
    [[ "$c" == 1 ]] && diagnostics
    exit 0
  fi
  if [[ -x "$XUI_BIN" || -f "$XUI_DB" || -e /etc/nginx/sites-enabled/vpn-node.conf ]]; then
    die "Найдена существующая/частичная конфигурация без маркера установщика. Ничего не перезаписываю."
  fi
}

diagnostics(){
  info "Диагностика"
  printf 'nginx: %s\n' "$(systemctl is-active nginx 2>/dev/null || true)"
  printf 'x-ui: %s\n' "$(systemctl is-active x-ui 2>/dev/null || true)"
  printf 'certbot.timer: %s\n' "$(systemctl is-active certbot.timer 2>/dev/null || true)"
  printf 'IPv6 disabled: %s\n' "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '?')"
  ufw status 2>/dev/null | head -n5 || true
  ss -ltnp | grep -E ':22|:80|:443|:2096|:10000|nginx|x-ui|xray' || true
  if [[ -n "${DOMAIN:-}" ]]; then
    curl -4fsS --max-time 10 "https://${DOMAIN}/health" || true; echo
  fi
}

disable_ipv6(){
  info "Отключаю IPv6"
  install -d -m755 /etc/sysctl.d
  cat >/etc/sysctl.d/99-vpn-node-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null
  sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null
  sysctl --system >/dev/null
  [[ -f /etc/default/ufw ]] && sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw || true
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]] || die "IPv6 не отключился."
  ip -6 addr show scope global | grep -q inet6 && die "После отключения остался глобальный IPv6." || true
}

telegram_test(){
  info "Проверяю Telegram и обычный интернет"
  local failed=0 t h p
  for t in api.telegram.org:443 149.154.167.41:80 149.154.167.41:443 149.154.167.50:80 149.154.167.50:443; do
    h="${t%:*}"; p="${t##*:}"
    if timeout 6 bash -c "cat < /dev/null > /dev/tcp/${h}/${p}" 2>/dev/null; then
      printf '  %-28s CONNECTED\n' "$t"
    else
      printf '  %-28s FAILED\n' "$t"; failed=1
    fi
  done
  curl -4fsSI --connect-timeout 8 --max-time 15 https://www.google.com/ >/dev/null 2>&1 || failed=1
  if ((failed)); then
    warn "Сетевой preflight не пройден."
    read -r -p "Всё равно продолжить? [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]] || exit 2
  fi
}

install_packages(){
  info "Устанавливаю пакеты"
  apt-get update
  local p=(nginx certbot python3-certbot-nginx apache2-utils curl wget unzip socat sqlite3 rsync ca-certificates dnsutils netcat-openbsd ufw python3)
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${p[@]}"; then
    warn "apt/dpkg споткнулся; применяю известный nginx IPv6-listen fix."
    [[ -f /etc/nginx/sites-available/default ]] && {
      sed -i -E 's/^([[:space:]]*)listen \[::\]:80 default_server;/\1# listen [::]:80 default_server;/' /etc/nginx/sites-available/default
      sed -i -E 's/^([[:space:]]*)listen \[::\]:443 ssl default_server;/\1# listen [::]:443 ssl default_server;/' /etc/nginx/sites-available/default
    }
    dpkg --configure -a
    DEBIAN_FRONTEND=noninteractive apt-get -f install -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${p[@]}"
  fi
  [[ -f /etc/nginx/sites-available/default ]] && {
    sed -i -E 's/^([[:space:]]*)listen \[::\]:80 default_server;/\1# listen [::]:80 default_server;/' /etc/nginx/sites-available/default
    sed -i -E 's/^([[:space:]]*)listen \[::\]:443 ssl default_server;/\1# listen [::]:443 ssl default_server;/' /etc/nginx/sites-available/default
  }
  nginx -t
}

configure_ufw(){
  local ssh_port="$1"
  info "Настраиваю UFW: SSH=${ssh_port}/tcp, 80/tcp, 443/tcp"
  sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp"
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
}

authoritative_ns(){
  local n="$1"; local -a a=()
  while [[ "$n" == *.* ]]; do
    mapfile -t a < <(dig +short NS "$n" | sed 's/\.$//' | sort -u)
    ((${#a[@]})) && { printf '%s\n' "${a[@]}"; return; }
    n="${n#*.}"
  done
  return 1
}

auth_dns_ok(){
  local d="$1" expected="$2" ns v6; local -a nss ans
  mapfile -t nss < <(authoritative_ns "$d" || true)
  ((${#nss[@]})) || return 1
  for ns in "${nss[@]}"; do
    mapfile -t ans < <(dig +short @"$ns" A "$d" | sort -u)
    ((${#ans[@]}==1)) && [[ "${ans[0]}" == "$expected" ]] || return 1
    v6=$(dig +short @"$ns" AAAA "$d" | head -n1); [[ -z "$v6" ]] || return 1
  done
}

public_dns_ok(){
  local d="$1" expected="$2" r v6; local -a ans
  for r in 1.1.1.1 8.8.8.8 9.9.9.9; do
    mapfile -t ans < <(dig +short @"$r" A "$d" | sort -u)
    ((${#ans[@]}==1)) && [[ "${ans[0]}" == "$expected" ]] || return 1
    v6=$(dig +short @"$r" AAAA "$d" | head -n1); [[ -z "$v6" ]] || return 1
  done
}

print_dns(){
  local d="$1" ns r; local -a nss
  mapfile -t nss < <(authoritative_ns "$d" || true)
  echo "Authoritative:"
  for ns in "${nss[@]}"; do printf '  %-28s A=%s AAAA=%s\n' "$ns" "$(dig +short @"$ns" A "$d" | paste -sd, -)" "$(dig +short @"$ns" AAAA "$d" | paste -sd, -)"; done
  echo "Public resolvers:"
  for r in 1.1.1.1 8.8.8.8 9.9.9.9; do printf '  %-28s A=%s AAAA=%s\n' "$r" "$(dig +short @"$r" A "$d" | paste -sd, -)" "$(dig +short @"$r" AAAA "$d" | paste -sd, -)"; done
}

wait_dns(){
  local d="$1" ip="$2" waited=0 limit=600 step=30 c
  info "Жду DNS: A=${ip}, AAAA отсутствует"
  while true; do
    if auth_dns_ok "$d" "$ip" && public_dns_ok "$d" "$ip"; then print_dns "$d"; return; fi
    ((waited==0 || waited%120==0)) && print_dns "$d"
    if ((waited>=limit)); then
      if ! auth_dns_ok "$d" "$ip"; then
        warn "Authoritative DNS ещё не готов или существует AAAA."
        read -r -p "Ждать ещё 10 минут? [Y/n]: " c
        [[ "$c" =~ ^[Nn]$ ]] && exit 3
        waited=0; continue
      fi
      echo "Authoritative DNS правильный, но публичный кэш ещё старый."
      echo "1) Ждать ещё 10 минут (рекомендуется)"
      echo "2) Попробовать выпуск сертификата"
      echo "3) Выйти"
      read -r -p "Выберите [1/2/3]: " c
      case "$c" in 2) return;; 3) exit 3;; *) waited=0;; esac
    fi
    printf '\rDNS: %d/%d сек...' "$waited" "$limit"
    sleep "$step"; waited=$((waited+step))
  done
}

write_assets(){
  info "Создаю сервисную страницу"
  install -d -m755 "$ACME_ROOT/.well-known/acme-challenge" "$WEB_ROOT" "$STATIC_ROOT"
  cat >"$WEB_ROOT/index.html" <<'HTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><link rel="icon" type="image/svg+xml" href="/favicon.svg"><title>Service endpoint</title><style>body{font-family:system-ui,sans-serif;max-width:44rem;margin:12vh auto;padding:0 1.5rem;color:#222}p{color:#666}</style></head><body><h1>Service endpoint</h1><p>The service is available.</p></body></html>
HTML
  cat >"$STATIC_ROOT/favicon.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#18212f"/><path d="M32 10 50 18v14c0 13-8 19-18 24C22 51 14 45 14 32V18z" fill="#3782f6"/><path d="m22 30 8 9 13-17" fill="none" stroke="#fff" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/></svg>
SVG
  echo acme-ok >"$ACME_ROOT/.well-known/acme-challenge/test"
  chmod 644 "$WEB_ROOT/index.html" "$STATIC_ROOT/favicon.svg" "$ACME_ROOT/.well-known/acme-challenge/test"
}

write_http_nginx(){
  local d="$1"
  info "Создаю HTTP nginx для ACME"
  cat >/etc/nginx/sites-available/vpn-node.conf <<EOF
server {
  listen 80;
  server_name $d;
  server_tokens off;
  location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; try_files \$uri =404; }
  location = / { root $WEB_ROOT; try_files /index.html =404; }
  location = /favicon.svg { alias $STATIC_ROOT/favicon.svg; default_type image/svg+xml; }
  location = /favicon.ico { alias $STATIC_ROOT/favicon.svg; default_type image/svg+xml; }
  location / { return 404; }
}
EOF
  ln -sfn /etc/nginx/sites-available/vpn-node.conf /etc/nginx/sites-enabled/vpn-node.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_cert(){
  local d="$1"
  info "Выпускаю Let's Encrypt сертификат"
  certbot certonly --webroot -w "$ACME_ROOT" -d "$d" --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring
  [[ -s "/etc/letsencrypt/live/$d/fullchain.pem" && -s "/etc/letsencrypt/live/$d/privkey.pem" ]] || die "Сертификат не найден."
  install -d -m755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  systemctl enable --now certbot.timer
}

install_3xui(){
  local port="$1" base="$2" user="$3" pass="$4" f
  info "Ставлю latest 3x-ui"
  f=$(mktemp /root/3x-ui-install.XXXXXX.sh); chmod 700 "$f"
  curl -fsSL "$UPSTREAM_INSTALL" -o "$f"
  XUI_NONINTERACTIVE=1 XUI_DB_TYPE=sqlite XUI_USERNAME="$user" XUI_PASSWORD="$pass" XUI_PANEL_PORT="$port" XUI_WEB_BASE_PATH="$base" XUI_SSL_MODE=none bash "$f"
  rm -f "$f"
  [[ -x "$XUI_BIN" && -f "$XUI_DB" ]] || die "3x-ui не установился полностью."
  "$XUI_BIN" setting -listenIP 127.0.0.1 >/dev/null
  "$XUI_BIN" setting -webBasePath "/$base/" >/dev/null
  systemctl stop x-ui
  sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO settings(key,value) VALUES('subEnable','false'); UPDATE settings SET value='false' WHERE key='subEnable';"
  systemctl start x-ui; sleep 3
  [[ "$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webListen' LIMIT 1;")" == 127.0.0.1 ]] || die "Панель не привязана к localhost."
  [[ "$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;")" == "$port" ]] || die "Порт панели отличается от заданного."
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)2096$' && die "2096 всё ещё слушает." || true
}

api_token(){
  local token=""
  if [[ -r /etc/x-ui/install-result.env ]]; then . /etc/x-ui/install-result.env; token="${XUI_API_TOKEN:-}"; fi
  [[ -n "$token" ]] || token=$($XUI_BIN setting -getApiToken 2>/dev/null | awk -F': ' '/apiToken:/ {print $2;exit}' | tr -d '[:space:]')
  [[ -n "$token" ]] || die "Не удалось получить API token 3x-ui."
  echo "$token"
}

create_inbound(){
  local port="$1" path="$2" token="$3" name="$4" uuid="$5" client="$6" api payload resp code ok
  info "Создаю VLESS WS inbound и клиента $client с UUID v4"
  api="http://127.0.0.1:${port}${path}panel/api"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "$api/server/status" || true)
  [[ "$code" == 200 ]] || die "Local API 3x-ui недоступен (HTTP $code)."
  payload=$(mktemp /root/vpn-node-inbound.XXXXXX.json); resp=$(mktemp /root/vpn-node-response.XXXXXX.json); chmod 600 "$payload" "$resp"
  python3 - "$payload" "$name" "$uuid" "$client" <<'PY'
import json,sys
p,name,uid,client=sys.argv[1:]
settings={"clients":[{"id":uid,"email":client,"flow":"","limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":0,"subId":"","comment":"","reset":0}],"decryption":"none","encryption":"none","fallbacks":[]}
stream={"network":"ws","security":"none","wsSettings":{"acceptProxyProtocol":False,"path":"/client/api/v2","host":"","headers":{},"heartbeatPeriod":0},"sockopt":{"trustedXForwardedFor":["X-Real-IP"]}}
obj={"up":0,"down":0,"total":0,"remark":name,"enable":True,"expiryTime":0,"trafficReset":"never","trafficResetDay":1,"lastTrafficResetTime":0,"listen":"127.0.0.1","port":10000,"protocol":"vless","settings":json.dumps(settings,separators=(',',':')),"streamSettings":json.dumps(stream,separators=(',',':')),"sniffing":json.dumps({"enabled":False}),"tag":"in-10000-tcp","shareAddrStrategy":"node","shareAddr":"","subSortIndex":1,"disableFlow":False}
json.dump(obj,open(p,'w'),separators=(',',':'))
PY
  code=$(curl -sS -o "$resp" -w '%{http_code}' -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data-binary "@$payload" "$api/inbounds/add" || true)
  rm -f "$payload"
  [[ "$code" == 200 ]] || { rm -f "$resp"; die "3x-ui API не создал inbound (HTTP $code)."; }
  ok=$(python3 - "$resp" <<'PY'
import json,sys
try: print('1' if json.load(open(sys.argv[1])).get('success') is True else '0')
except Exception: print('0')
PY
)
  rm -f "$resp"; [[ "$ok" == 1 ]] || die "3x-ui API вернул success=false."
  sleep 2
  ss -ltnH | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${XRAY_PORT}$" || { systemctl restart x-ui; sleep 3; }
  ss -ltnH | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${XRAY_PORT}$" || die "Xray не слушает 127.0.0.1:${XRAY_PORT}."
  python3 - "$XUI_DB" "$uuid" "$client" <<'PY'
import json,sqlite3,sys
r=sqlite3.connect(sys.argv[1]).execute("SELECT settings FROM inbounds WHERE port=10000 AND protocol='vless' LIMIT 1").fetchone()
if not r: raise SystemExit(1)
c=json.loads(r[0]).get('clients') or []
raise SystemExit(0 if any(x.get('id')==sys.argv[2] and x.get('email')==sys.argv[3] for x in c) else 1)
PY
}

basic_auth(){
  local pass="$1"
  info "Создаю Basic Auth user=$BASIC_USER"
  printf '%s\n' "$pass" | htpasswd -ci "$HTPASSWD" "$BASIC_USER" >/dev/null
  chown root:www-data "$HTPASSWD"; chmod 640 "$HTPASSWD"
}

write_final_nginx(){
  local d="$1" port="$2" panel="$3" no="${3%/}"
  info "Записываю финальный nginx"
  cat >/etc/nginx/sites-available/vpn-node.conf <<EOF
server {
  listen 80;
  server_name $d;
  server_tokens off;
  location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; try_files \$uri =404; }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl http2;
  server_name $d;
  server_tokens off;
  ssl_certificate /etc/letsencrypt/live/$d/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$d/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  location ^~ /.well-known/acme-challenge/ { root $ACME_ROOT; default_type text/plain; try_files \$uri =404; }
  location = / { root $WEB_ROOT; try_files /index.html =404; }
  location = /favicon.svg { alias $STATIC_ROOT/favicon.svg; default_type image/svg+xml; }
  location = /favicon.ico { alias $STATIC_ROOT/favicon.svg; default_type image/svg+xml; }
  location ^~ $WS_PATH {
    proxy_pass http://127.0.0.1:$XRAY_PORT;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_buffering off;
  }
  location = $no { return 301 $panel; }
  location ^~ $panel {
    auth_basic "Restricted";
    auth_basic_user_file $HTPASSWD;
    proxy_pass http://127.0.0.1:$port;
    proxy_http_version 1.1;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Accept-Encoding "";
    sub_filter_once on;
    sub_filter '</head>' '<link rel="icon" type="image/svg+xml" href="/favicon.svg"></head>';
    proxy_read_timeout 300s;
  }
  location = /health { default_type application/json; return 200 '{"status":"ok"}'; }
  location = /version { default_type application/json; return 200 '{"service":"vpn-node","installer":"vpn-node-installer","version":"$VERSION"}'; }
  location = /robots.txt { default_type text/plain; return 200 "User-agent: *\nDisallow: /\n"; }
  location / { return 404; }
}
EOF
  nginx -t; systemctl reload nginx
}

final_checks(){
  local d="$1" port="$2" panel="$3" code h
  info "Финальные проверки"
  [[ "$(systemctl is-active nginx)" == active ]] || die "nginx не active."
  [[ "$(systemctl is-active x-ui)" == active ]] || die "x-ui не active."
  [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]] || die "IPv6 включён."
  ip -6 addr show scope global | grep -q inet6 && die "Есть глобальный IPv6." || true
  ss -ltnH | awk '{print $4}' | grep -Eq '0\.0\.0\.0:80$' || die "Нет 0.0.0.0:80."
  ss -ltnH | awk '{print $4}' | grep -Eq '0\.0\.0\.0:443$' || die "Нет 0.0.0.0:443."
  ss -ltnH | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${port}$" || die "Панель не на localhost."
  ss -ltnH | awk '{print $4}' | grep -Eq "127\.0\.0\.1:${XRAY_PORT}$" || die "Xray не на localhost."
  ss -ltnH | awk '{print $4}' | grep -Eq "0\.0\.0\.0:(${port}|${XRAY_PORT}|2096)$" && die "Внутренний порт открыт наружу." || true
  ss -ltnH | awk '{print $4}' | grep -Eq '(^|:)2096$' && die "2096 слушает." || true
  h=$(curl -4fsS --max-time 15 "https://$d/health"); [[ "$h" == '{"status":"ok"}' ]] || die "/health неверный."
  code=$(curl -4ksS -o /dev/null -w '%{http_code}' --max-time 15 "https://$d$panel" || true); [[ "$code" == 401 ]] || die "Panel without Basic Auth: HTTP $code, expected 401."
  code=$(curl -4ksS --http1.1 --connect-timeout 10 --max-time 2 -o /dev/null -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$d$WS_PATH" 2>/dev/null || true); [[ "$code" == 101 ]] || die "WS handshake: HTTP $code, expected 101."
  openssl x509 -in "/etc/letsencrypt/live/$d/fullchain.pem" -noout -subject -issuer -dates
  telegram_test
  certbot renew --dry-run
}

write_state(){
  local d="$1" ip="$2" port="$3" panel="$4" name="$5" client="$6"
  install -d -m700 "$STATE_DIR"
  { printf 'INSTALLER_VERSION=%q\n' "$VERSION"; printf 'DOMAIN=%q\n' "$d"; printf 'PUBLIC_IPV4=%q\n' "$ip"; printf 'PANEL_PORT=%q\n' "$port"; printf 'PANEL_PATH=%q\n' "$panel"; printf 'INBOUND=%q\n' "$name"; printf 'CLIENT=%q\n' "$client"; } >"$STATE_FILE"
  chmod 600 "$STATE_FILE"; echo "$VERSION" >"$MARKER"; chmod 600 "$MARKER"
}

summary(){
  local d="$1" ip="$2" panel="$3" name="$4" uuid="$5" client="$6"
  local link="vless://${uuid}@${d}:443?type=ws&encryption=none&security=tls&sni=${d}&host=${d}&path=%2Fclient%2Fapi%2Fv2&alpn=http%2F1.1#${client}"
  cat <<EOF

======================================================================
УСТАНОВКА ЗАВЕРШЕНА
IPv4       : $ip
Домен      : $d
Панель     : https://$d$panel
Basic Auth : $BASIC_USER / (ваш пароль)
Inbound    : $name
Клиент     : $client
WS path    : $WS_PATH
Xray local : 127.0.0.1:$XRAY_PORT
IPv6       : отключён

VLESS link (сохраните приватно):
$link

Лог без паролей/UUID: $LOG
Следующий обязательный шаг: реальный клиентский тест Telegram/сайтов через VPN.
======================================================================
EOF
}

install_client_helper(){
  local tmp
  tmp=$(mktemp /root/vpn-clients-helper.XXXXXX.sh)
  if ! curl -fsSL "$CLIENT_HELPER_URL" -o "$tmp"; then
    rm -f "$tmp"
    warn "Не удалось скачать clients.sh с GitHub. Сам VPN-узел уже установлен."
    return 1
  fi
  chmod 700 "$tmp"
  if ! bash -n "$tmp"; then
    rm -f "$tmp"
    warn "Скачанный clients.sh не прошёл bash -n. Сам VPN-узел уже установлен."
    return 1
  fi
  install -m755 "$tmp" "$CLIENT_HELPER_BIN"
  rm -f "$tmp"
  log "Installed client helper to $CLIENT_HELPER_BIN"
}

offer_add_clients(){
  local answer
  if [[ ! -x "$CLIENT_HELPER_BIN" ]]; then
    install_client_helper || return 0
  fi
  printf '\n'
  read -r -p "Добавить дополнительных клиентов сейчас? [y/N]: " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Пропущено. Позже можно запустить: sudo vpn-clients"
    return 0
  fi
  if ! "$CLIENT_HELPER_BIN"; then
    warn "Добавление клиентов завершилось с ошибкой. Основная установка VPN уже завершена; повторить можно командой: sudo vpn-clients"
  fi
}

main(){
  need_root; need_tty; check_os; existing_guard
  command -v curl >/dev/null || { apt-get update; apt-get install -y curl ca-certificates python3; }

  echo "vpn-node-installer $VERSION"
  local domain key panel_base panel_path panel_port xuser xpass bpass uuid ip token ssh_port client_name
  while true; do
    read -r -p "Домен узла (например vpn.example.ru): " domain
    domain=$(tr '[:upper:]' '[:lower:]' <<<"$domain" | tr -d '[:space:]')
    valid_domain "$domain" && break
    echo "Некорректный домен."
  done
  key=$(domain_key "$domain"); [[ -n "$key" ]] || die "Не удалось получить имя перед зоной."
  panel_base="dashboard-$key"; panel_path="/$panel_base/"
  panel_port=$(free_panel_port) || die "Нет свободного порта панели."
  client_name="default@$domain"
  prompt_nonempty xuser "Логин 3x-ui: "
  prompt_secret xpass "Пароль 3x-ui"
  echo "Basic Auth логин: $BASIC_USER"
  prompt_secret bpass "Пароль Basic Auth"
  uuid=$(uuid_v4)
  ssh_port=$(ssh_server_port)

  info "Начинаю установку: domain=$domain panel=$panel_path inbound=$key client=$client_name"
  disable_ipv6
  telegram_test
  install_packages
  ip=$(public_ipv4) || die "Не удалось определить публичный IPv4."
  echo "Публичный IPv4: $ip"
  echo "Текущий SSH-порт: $ssh_port"
  configure_ufw "$ssh_port"
  wait_dns "$domain" "$ip"
  write_assets
  write_http_nginx "$domain"
  issue_cert "$domain"
  install_3xui "$panel_port" "$panel_base" "$xuser" "$xpass"
  token=$(api_token)
  create_inbound "$panel_port" "$panel_path" "$token" "$key" "$uuid" "$client_name"
  unset token
  rm -f /etc/x-ui/install-result.env
  basic_auth "$bpass"
  unset bpass xpass
  write_final_nginx "$domain" "$panel_port" "$panel_path"
  final_checks "$domain" "$panel_port" "$panel_path"
  write_state "$domain" "$ip" "$panel_port" "$panel_path" "$key" "$client_name"
  log "Installation completed domain=$domain ip=$ip version=$VERSION"
  summary "$domain" "$ip" "$panel_path" "$key" "$uuid" "$client_name"
  offer_add_clients
}

main "$@"