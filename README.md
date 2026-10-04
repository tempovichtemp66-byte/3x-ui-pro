# 3x-ui-pro

🇬🇧 [English version](README_EN.md)

Автоматическая установка панели [3x-ui](https://github.com/MHSanaei/3x-ui) v3+: один домен, все протоколы на порту 443, вечный пользователь с подпиской, сайт-заглушка, WARP-выход и готовый роутинг RoscomVPN для Happ.

> [!WARNING]
> **Проект создан в образовательных целях.** Убедитесь, что ваши действия соответствуют законодательству вашей страны.
> Используйте только на собственных серверах. Авторы не несут ответственности за применение и возможный ущерб.
> Полный текст — [DISCLAIMER.md](DISCLAIMER.md).

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
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-latest.sh) -subdomain panel.example.com
```

Без `-subdomain` домен спросят интерактивно.

**Переустановка** — та же команда. Скрипт сам удалит старую панель/БД/nginx-конфиги и поставит всё заново (новые порты, пути, UUID клиентов и ссылки — ищите их в `/root/README_PANEL.md`). Существующие сертификаты Let's Encrypt при этом **не перевыпускаются** (если `/etc/letsencrypt/live/<домен>/` на месте — certbot не запускается, лимиты LE не тратятся). Если переустанавливаете master-ноду — сначала удалите slave-ноды (`x-ui-node.sh -del ...`), чтобы не осталось «висящих» клиентов на slave.

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

## Вечные пользователи

По умолчанию создаются **10 бессрочных пользователей** (`-users N`, 1–100):

- **`eternal-1 … eternal-10`** — все протоколы, кроме WireGuard/AmneziaWG (у панели
  одна общая WireGuard-пара ключей на клиента, поэтому туннели вынесены отдельно):
  срок действия **никогда**, лимит трафика **безлимит**;
- **`eternal-N-wg`** — только WireGuard (`wireguard://`);
- **`eternal-N-awg`** — только AmneziaWG (`vpn://` для AmneziaVPN).

В ссылки REALITY автоматически попадает `flow=xtls-rprx-vision`.

Скрипт печатает JSON-ссылку каждого пользователя, а полный список (панель + все
форматы подписок) сохраняется в **`/root/README_PANEL.md`** (0600):

```
https://<домен>/<путь>/eternal-1        # raw (все клиенты)
https://<домен>/<путь-json>/eternal-1   # JSON — рекомендовано для Happ (с роутингом)
https://<домен>/<путь-clash>/eternal-1  # Clash / Mihomo
https://<домен>/<путь>/eternal-1-wg     # WireGuard
https://<домен>/<путь>/eternal-1-awg    # AmneziaWG (vpn://)
```

> JSON-подписка панели не содержит TUIC, AmneziaWG и MTProto — это ограничение
> самой панели. Для Happ берите JSON-подписку, для AmneziaVPN — raw-подписку
> `eternal-N-awg`, для TUIC/MTProto — raw или Clash.

---

## Маскировка и заглушка

- Клиент REALITY подключается к `<ваш домен>:443` с SNI `www.bing.com` (или google/duckduckgo) и уходит в Xray.
- Посторонний, зашедший на `https://<ваш домен>`, получает **бесконечную загрузку** (JS-прогресс, который никогда не доходит до 100%).
- Любой другой SNI уходит в REALITY-цель — сканер видит настоящий TLS выбранного сайта.
- Перед установкой сайт маскировки проверяется на TLS 1.3 + HTTP/2; если выбранный недоступен — скрипт автоматически подберёт другой.
- MTProto автоматически пропускается, если с сервера недоступны серверы Telegram (прокси всё равно был бы бесполезен).

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

**MTU и выбор адресного семейства определяются автоматически.** Скрипт зондирует path MTU до WARP-endpoint (`ping -M do`) и подбирает MTU туннеля так, чтобы внешние пакеты гарантированно проходили (на сетях с MTU <1500, например AEZA/1448, жёсткий `1420` давал потери пакетов и задержки в секунды), а также предпочитает IPv4-anycast, если у хостера IPv6-путь якорится на дальний POP. Тот же MTU применяется к WireGuard-инбаунду.

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

## Мульти-нода: несколько серверов в одной подписке

Одна подписка мастера отдаёт подключения и к slave-серверам. Максимально просто — два шага:

**Шаг 1. На slave-сервере** выполните:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-node.sh) -slave
```

Скрипт сам определит домен, порт, путь панели, тип сертификата и выдаст готовую команду для мастера (например `bash x-ui-node.sh -node "Нидерланды|https|msk.example.com|443|/AbCdEf/|TOKEN"`). **Метка ноды по умолчанию — страна сервера** (`curl ifconfig.co/country`), переопределить можно через `-name "Моя метка"`.

**Шаг 2. На master-ноде** просто вставьте эту команду (или передайте строку как аргумент / через пайп):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-node.sh) -node "Москва|https|msk.example.com|443|/AbCdEf/|TOKEN"
# или просто строка:
bash <(curl -fsSL .../x-ui-node.sh) "Москва|https|msk.example.com|443|/AbCdEf/|TOKEN"
# или пайп:
echo "Москва|https|msk.example.com|443|/AbCdEf/|TOKEN" | bash <(curl -fsSL .../x-ui-node.sh)
```

Механика: нода регистрируется на мастере (мониторинг/статус), для каждого поддерживаемого инбаунда мастера создаётся **host-оверрайд** на адрес slave (`:443`, путь slave), а uuid вечных пользователей мастера **провижинятся на slave** — подписка `https://<мастер>/<sub-path>/<subid>` начинает отдавать дополнительные профили с адресами нод. Покрытие: `vless/trojan/vmess` поверх `ws/httpupgrade/xhttp` и `tcp+REALITY` (ключи REALITY slave синхронизируются с мастером), плюс `hysteria2`, `tuic` и `shadowsocks-2022` (клиенты/ключи провижинятся на slave). Не покрываются: gRPC (nginx-роутинг по портам + serviceName), kcp (ключи VLESS Encryption), wireguard/amneziawg (свои пары ключей), mtproto (отдельный демон mtg).

Прочее:

```bash
bash x-ui-node.sh -list                          # список нод
bash x-ui-node.sh -node "USA|...|TOKEN" -check   # здоровье + покрытие uuid
bash x-ui-node.sh -del "USA" -node "USA|...|TOKEN"  # удалить ноду (токен нужен для очистки клиентов на slave)
bash x-ui-node.sh -users 3 -node "..."           # только первых 3 пользователей
bash x-ui-node.sh -slave -name "Москва"          # явная метка вместо страны
curl ifconfig.co/country                          # что скрипт берёт как метку по умолчанию
```

⚠️ `x-ui setting -getApiToken true` (и режим `-slave`) **ротируют токен при каждом запуске**: каждая команда из `-slave` действительна только одна — после её выполнения не запускайте `-slave` повторно, иначе мастер начнёт получать 401/404 (лечится повторным запуском со свежей командой).

---

## Параметры запуска

| Параметр | Описание |
|----------|----------|
| `-subdomain <домен>` | Домен панели, подписок и заглушки |
| `-users N` | Сколько вечных пользователей создать (по умолчанию 10, диапазон 1–100) |
| `-label <строка>` | Метка, добавляемая к названиям подключений (remark инбаундов — видны в панели и в JSON-подписке Happ) и к подпискам в `README_PANEL.md`. **По умолчанию — страна сервера** (`curl ifconfig.co/country`), например `⚡ reality [The Netherlands]` |
| `-sni bing\|google\|duckduckgo\|<домен>` | Под какой сайт маскируется REALITY (по умолчанию `bing`; сайт проверяется на TLS 1.3 + HTTP/2, при недоступности подбирается другой) |
| `-cover endless\|random` | Заглушка: вечная загрузка или случайный сайт (по умолчанию `endless`) |
| `-xray_core <версия\|none>` | Ядро Xray. По умолчанию `v26.6.27`: в более новых ядрах (26.7+) ломается REALITY у Mihomo/sing-box (проверено на живом сервере 01.10.2026). `-xray_core none` — оставить ядро из комплекта панели |
| `-install n` | Пропустить установку системных пакетов (по умолчанию `y`) |
| `-auto_domain y` | Проверить, что домен уже указывает на этот IP |
| `-opencode y\|n` | Установить CLI **opencode** (по умолчанию `y`) — донастройка системы и панели из терминала |
| `-daily_reboot y\|n` | Полный перезапуск сервера каждый день в 00:00 (по умолчанию `y`) |
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

## Дюп сторонней подписки (x-ui-sub-dub.sh)

Скопировать чужую подписку к себе, чтобы лимиты устройств провайдера не действовали (запросы идут с вашего сервера):

```bash
wget -qO x-ui-sub-dub.sh https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-sub-dub.sh
bash x-ui-sub-dub.sh -url "https://sub.provider/abc" -name alvsub -interval 4
# → выдаст https://<ваш-домен>/<секрет> — импортируйте в клиент
bash x-ui-sub-dub.sh -list          # список дюпов
bash x-ui-sub-dub.sh -remove alvsub # удалить
```

Скрипт скачивает подписку с клиентским User-Agent (многие провайдеры браузерам отдают 502), проверяет валидность (base64-raw или JSON), кладёт в веб-корень под случайным путём и обновляет по cron (по умолчанию каждые 4 часа). ⚠️ Дюпать можно только то, что вам принадлежит или разрешено.

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
