# vpn-node-installer

Интерактивный установщик нового VPN-узла на чистой **Ubuntu 24.04 LTS x64**.

Текущая версия: **0.1.0-dev** — первый рабочий прототип, который ещё должен пройти реальную установку на тестовом VPS перед маркировкой как stable.

## Что собирает

```text
client → domain:443 → nginx (TLS) → /client/api/v2 → 127.0.0.1:10000 → Xray / VLESS / WebSocket
```

Панель:

```text
browser → https://domain/dashboard-<domain-name>/ → nginx Basic Auth → 127.0.0.1:<random-port> → 3x-ui
```

`<domain-name>` — имя непосредственно перед доменной зоной. Например:

- `backup.fs-s.ru` → `/dashboard-fs-s/`, inbound `fs-s`
- `r.reglament.net` → `/dashboard-reglament/`, inbound `reglament`
- `w.kmv-m.ru` → `/dashboard-kmv-m/`, inbound `kmv-m`

## Зафиксированные правила

- Ubuntu 24.04 LTS x64.
- IPv6 выключается сразу, в runtime и после reboot.
- AAAA-записи для VPN-домена не используются.
- VLESS over WebSocket.
- WebSocket path всегда `/client/api/v2`.
- Xray inbound всегда `127.0.0.1:10000`.
- 3x-ui слушает только `127.0.0.1` на случайном внутреннем порту.
- TLS завершается на nginx, внутри Xray `security=none`.
- Subscription server 3x-ui (`2096`) выключается.
- `trustedXForwardedFor = ["X-Real-IP"]` на WS inbound.
- nginx выставляет `X-Real-IP` и `X-Forwarded-For`.
- Первый клиент называется `default`.
- UUID клиента генерирует сам установщик как корректный UUID v4, а не панель.
- Basic Auth user всегда `admin`; пароль спрашивается.
- Логин и пароль 3x-ui спрашиваются отдельно.
- Let's Encrypt выпускается через certbot webroot без email.
- UFW разрешает только `22/tcp`, `80/tcp`, `443/tcp`.
- Способ SSH-аутентификации установщик не меняет.
- 3x-ui ставится как current `latest` из официального `MHSanaei/3x-ui`.
- Секреты, UUID и VLESS-ссылка не пишутся в постоянный лог.

## Preflight

До развёртывания VPN проверяются Telegram, обычный IPv4 Internet, публичный IPv4 сервера, authoritative DNS и резолверы `1.1.1.1`, `8.8.8.8`, `9.9.9.9`. A-запись должна указывать только на текущий IPv4, AAAA должна отсутствовать.

Если публичные DNS ещё держат старый кэш, установщик ждёт по 30 секунд до 10 минут, после чего позволяет продолжить ожидание или — только когда authoritative DNS уже корректны — попробовать выпуск сертификата.

## Финальные проверки

Установщик проверяет nginx/x-ui, отсутствие IPv6, UFW, внешние `80/443`, localhost-only панель и Xray, отсутствие `2096`, `/health`, Basic Auth → HTTP 401, WebSocket handshake → HTTP 101, сертификат, Telegram после установки и `certbot renew --dry-run`.

В финале показывается готовая VLESS-ссылка клиента `default`. Реальный клиентский тест через Hiddify/OneXray/Happ+ остаётся обязательной последней проверкой.

## Запуск dev-версии

Пока `0.1.0-dev` не прошла первый реальный VPS-тест, лучше сначала скачать скрипт и просмотреть его, а не запускать через `curl | bash`.

```bash
curl -fsSLO https://raw.githubusercontent.com/sliptip/vpn-node-installer/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## Повторный запуск

После успешной установки создаётся root-only state в `/etc/vpn-node-installer/`. Повторный запуск ничего не перезаписывает и предлагает только безопасную диагностику либо выход.

Если обнаружена чужая/частичная установка nginx/3x-ui без нашего маркера, скрипт останавливается.

## Лог

```text
/var/log/vpn-node-installer.log
```

Пароли, API token, UUID клиента и VLESS-ссылка туда не записываются.
