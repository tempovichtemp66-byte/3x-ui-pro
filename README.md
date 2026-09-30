# 3x-ui-pro

🇬🇧 [English version](README_EN.md)

Автоматическая установка панели [3x-ui](https://github.com/MHSanaei/3x-ui) v3+: один домен, все протоколы на порту 443, вечный пользователь с подпиской, сайт-заглушка, WARP-выход и готовый роутинг RoscomVPN для Happ.

- Debian 12/13, Ubuntu 24.04/26.04
- **Один домен** (второй reality-домен больше не нужен)
- REALITY маскируется под **bing / google / duckduckgo** (SNI + fallback на реальный сайт)
- Все TCP-протоколы на **443** через SNI-роутер nginx; Hysteria2 — на **UDP 443**
- Из коробки **пользователь `eternal`** — без срока действия и без лимита трафика, привязан ко всем входам
- Сайт-заглушка с **вечной загрузкой** (опционально — случайный из 50 сайтов)
- Весь исходящий трафик клиентов идёт через **Cloudflare WARP**
- В JSON-подписку встроен роутинг [RoscomVPN](https://github.com/hydraponique/roscomvpn-routing) для Happ

---

## Что устанавливается

| Компонент | Описание |
|-----------|----------|
| 3x-ui | VPN-панель с веб-интерфейсом |
| nginx | SNI-роутер на 443 + TLS-терминация транспортов |
| certbot | Let's Encrypt SSL (один домен) |
| Подписки | Raw + JSON (Happ) + Clash — встроенный сервер подписок 3x-ui |
| Диагностика | MTR-трейсер + тест скорости в браузере (по сессии панели) |
| Заглушка | Страница «вечная загрузка» (по умолчанию) |
| WARP | Cloudflare WARP как исходящий шлюз (регистрируется через API панели) |
| Бэкап | Скрипт резервного копирования |
| AdGuard Home | Опционально: DNS с блокировкой рекламы (DoH) — отдельный скрипт |

---

## Установка

```bash
wget -qO x-ui-latest.sh https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-latest.sh
bash x-ui-latest.sh -subdomain panel.example.com
```

Без `-subdomain` домен спросят интерактивно.

> Ассеты (заглушка, диагностика) скачиваются из этого репозитория. Если вы форкнули
> и переименовали его — поменяйте `tempovichtemp66-byte/3x-ui-pro` в файлах или задайте окружение:
> `XUI_PRO_RAW=https://raw.githubusercontent.com/<вы>/<репо>/main bash x-ui-latest.sh ...`.
> Сама панель 3x-ui при этом всё равно скачивается из оригинального репозитория MHSanaei/3x-ui.

---

## Входы (inbounds) из коробки

### TCP 443 (nginx SNI-роутер)

| Вход | Транспорт | Как попадает на 443 |
|------|-----------|---------------------|
| VLESS | REALITY (TCP), flow `xtls-rprx-vision` | маскировочный SNI (`www.bing.com` и т.п.) |
| VLESS | WebSocket | путь `/<порт>/<random>` через nginx |
| VLESS | gRPC | путь `/<порт>/<random>` (HTTP/2 gRPC) |
| VLESS | HTTPUpgrade | путь `/<порт>/<random>` |
| VLESS | XHTTP `packet-up` | путь `/<порт>/<random>` |
| Trojan | WebSocket, gRPC | путь `/<порт>/<random>` |
| VMess | WebSocket, gRPC | путь `/<порт>/<random>` |
| MTProto | mtg-multi (FakeTLS) | SNI `www.cloudflare.com` через nginx |

### UDP 443

| Вход | Описание |
|------|----------|
| Hysteria2 | QUIC, сертификат домена, маскарад = сайт-заглушка |

### Отдельные порты (физически не могут жить на 443)

| Вход | Транспорт | Порт |
|------|-----------|------|
| VLESS | mKCP* | случайный UDP |
| TUIC v5 | QUIC | случайный UDP |
| WireGuard | UDP | случайный UDP |
| AmneziaWG | UDP | случайный UDP |
| Shadowsocks-2022 | TCP+UDP | случайный TCP |

Порты генерируются случайно один раз и сохраняются в `/etc/x-ui/3x-ui-pro/install.env` — повторный запуск и `x-ui-patch.sh` их не меняют.

\* mKCP собирается с **VLESS Encryption** (X25519): современные ядра Xray запрещают «голый» VLESS без TLS, поэтому ссылки mKCP требуют клиента с поддержкой VLESS Encryption (Xray 25.x+, свежий Happ).

\* **AmneziaWG** получает случайный набор обфускации **AmneziaWG 3.1** — его генерирует сама панель (как при создании инбаунда через UI): Jc/Jmin/Jmax, S1–S4, H1–H4, I1, header protection, тайминги, RandomTrailers/DisableCookies. Для импорта `vpn://` нужен свежий AmneziaVPN с поддержкой 3.1.

---

## Вечная подписка

После установки создаются три бессрочных клиента:

- **`eternal`** — все протоколы, кроме WireGuard/AmneziaWG (у панели одна общая
  WireGuard-пара ключей на клиента, поэтому туннели вынесены отдельно):
  срок действия **никогда**, лимит трафика **безлимит**;
- **`eternal-wg`** — только WireGuard (`wireguard://`);
- **`eternal-awg`** — только AmneziaWG (`vpn://` для AmneziaVPN).

В ссылки REALITY автоматически попадает `flow=xtls-rprx-vision`.

Скрипт выводит URL подписок:

```
https://<домен>/<путь>/eternal        # raw (все клиенты)
https://<домен>/<путь-json>/<subid>   # JSON — рекомендовано для Happ (с роутингом)
https://<домен>/<путь-clash>/<subid>  # Clash / Mihomo
https://<домен>/<путь>/<subid-wg>     # WireGuard
https://<домен>/<путь>/<subid-awg>    # AmneziaWG (vpn://)
```

> JSON-подписка панели не содержит TUIC, AmneziaWG и MTProto — это ограничение
> самой панели. Для Happ берите JSON-подписку, для AmneziaVPN — raw-подписку
> `eternal-awg`, для TUIC/MTProto — raw или Clash.

---

## Маскировка и заглушка

- Клиент REALITY подключается к `<ваш домен>:443` с SNI `www.bing.com` (или google/duckduckgo) и уходит в Xray.
- Посторонний, зашедший на `https://<ваш домен>`, получает **бесконечную загрузку** (JS-прогресс, который никогда не доходит до 100%).
- Любой другой SNI уходит в REALITY-цель — сканер видит настоящий TLS выбранного сайта.

Выбор маскировочного SNI:

```bash
bash x-ui-latest.sh -subdomain panel.example.com -sni google
# или -sni bing (по умолчанию), -sni duckduckgo
```

Заглушка:

```bash
bash x-ui-latest.sh -subdomain panel.example.com -cover random   # случайный сайт из 50
bash x-ui-latest.sh -subdomain panel.example.com -cover endless  # вечная загрузка (по умолчанию)
```

---

## WARP (исходящий трафик)

Скрипт регистрирует устройство в Cloudflare WARP через API панели и добавляет в конфиг Xray:

- outbound `warp` (WireGuard, `noKernelTun`, IPv4/IPv6);
- маршрутизацию: приватные сети → `direct`, всё остальное → `warp`.

Если регистрация не удалась, конфиг остаётся на `direct` (доступ не теряется), включить WARP можно вручную: **Xray → WARP** в панели.

---

## Роутинг RoscomVPN для Happ

В настройке `subJsonRoutingRules` прописан профиль
`hydraponique/roscomvpn-routing` (`HAPP/DEFAULT.JSON`): RU/BY — напрямую,
YouTube/Telegram/GitHub и остальной мир — через прокси, реклама блокируется.
Панель сама печёт DNS и routing в JSON-подписку и отдаёт Happ-заголовок `Routing`
(вместе с ссылками на кастомные geoip/geosite). Для полноценной работы импортируйте
именно **JSON-подписку**.

---

## Параметры запуска

| Параметр | Описание |
|----------|----------|
| `-subdomain <домен>` | Домен панели, подписок и заглушки |
| `-sni bing\|google\|duckduckgo` | Под какой сайт маскируется REALITY (по умолчанию `bing`) |
| `-cover endless\|random` | Заглушка: вечная загрузка или случайный сайт (по умолчанию `endless`) |
| `-install n` | Пропустить установку системных пакетов (по умолчанию `y`) |
| `-auto_domain y` | Проверить, что домен уже указывает на этот IP |
| `-version <версия>` | Установить конкретную версию 3x-ui, по умолчанию — последняя |
| `-uninstall y` | Полное удаление |
| `-patch y` | Пере-применить конфигурацию (используется `x-ui-patch.sh`) |

---

## Патч

Пере-применяет текущую конфигурацию к существующей установке, **не меняя** домен,
порты, пути подписок и UUID/пароли клиентов (они берутся из
`/etc/x-ui/3x-ui-pro/install.env` и БД):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-patch.sh)
```

Патч работает для установок, созданных этой версией скрипта. Для перехода со старой
двухдоменной версии рекомендуется чистая установка.

---

## AdGuard Home (опционально)

Устанавливает [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) на домен панели:

- **DNS-over-HTTPS** для клиентов: `https://<домен-панели>/dns-query`
- **Админка** — на случайном пути `/adg-<random>/` (логин и пароль выводит скрипт)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-adguard.sh)
```

Повторный запуск безопасен. После установщика или патча запустите скрипт ещё раз — они перезаписывают конфиг nginx.

Удаление:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-adguard.sh) -uninstall y
```

---

## Удаление

```bash
bash x-ui-latest.sh -uninstall y
```

---

## Бэкап и восстановление

```bash
wget -qO /usr/local/bin/x-ui-backup https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/assets/backup/x-ui-backup.sh
chmod +x /usr/local/bin/x-ui-backup

x-ui-backup backup                  # создать
x-ui-backup list                    # список
x-ui-backup restore <архив>         # восстановить
```

Бэкап включает: конфиги nginx, БД панели, бинарник 3x-ui, SSL-сертификаты, веб-контент, systemd-юниты, cron, правила UFW.

---

## Диагностика сети

Доступна по ссылке, которую выводит скрипт (`.../<панель>/diag`), после входа в панель:

- MTR-трейс
- Тест скорости загрузки/отдачи (LibreSpeed)
- Информация о сервере
