# 3x-ui-pro

Single-domain installer for the 3x-ui v3+ VPN panel: all TCP protocols on :443 via
an nginx SNI router, Hysteria2 on UDP :443, an eternal subscription client, an
endless-loading cover site, RoscomVPN routing for Happ and Cloudflare WARP egress.

## Repository structure

```
x-ui-latest.sh          — main installer (single file, run remotely)
x-ui-patch.sh           — thin bootstrap: re-runs x-ui-latest.sh with -patch y
x-ui-adguard.sh         — optional: AdGuard Home on the panel domain (DoH at
                          /dns-query, admin UI at random /adg-<rand>/ path)
assets/
  backup/x-ui-backup.sh — backup / restore / list script
  decoy/index.html      — endless-loading cover page (default)
  fake-sites/
    site-01 … site-50/  — static HTML cover pages (-cover random)
  diagnostics/
    index.html          — network diagnostics page (speed test, MTR, test files)
    mtr-backend.py      — localhost-only backend: MTR + LibreSpeed endpoints
    librespeed/         — vendored LibreSpeed engine (LGPL)
```

Scripts download assets at install time from this repo's raw GitHub URL
(`https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/...`, overridable with
`XUI_PRO_RAW`) — changes take effect on servers only after push to `main`.

## Architecture

```
:443/tcp  nginx stream (ssl_preread SNI router)
            <mask SNI>            -> Xray REALITY     127.0.0.1:$reality_port
            <domain>              -> nginx vhost      127.0.0.1:7443
            www.cloudflare.com    -> mtg sidecar      127.0.0.1:$mtproto_port
            default               -> Xray REALITY
:443/udp  Xray Hysteria2 (TLS with the domain cert, masquerade = /var/www/html)
:80/tcp   nginx -> 301 https
<random>  mKCP / TUIC / WireGuard / AmneziaWG (UDP), Shadowsocks-2022 (TCP+UDP)
```

The nginx vhost (TLS-terminated at 7443 with the domain certificate) serves the
panel, the raw/JSON/Clash subscriptions, diagnostics and path-routes the Xray
transports:

* `/<local_port>/<random>` — one regex location for WebSocket, gRPC
  (`content_type: application/grpc` -> `grpc_pass`), HTTPUpgrade and XHTTP
  `packet-up` (`noGRPCHeader`), dispatching on the first path segment;
* XHTTP is bound to a loopback TCP port with `mode=packet-up` + `noGRPCHeader`
  so it works over HTTP/1.1 proxy_pass;
* subscription paths are random and proxied to the panel's built-in sub server
  (`subPath`, `subJsonPath`, `subClashPath` + `subEnable`/`subJsonEnable`/
  `subClashEnable`).

REALITY steals nothing locally: `target`/`serverNames` are the masking site
(`www.bing.com` / `www.google.com` / `duckduckgo.com`), so unauthenticated probes
transparently land on the real site.

## How the installer drives the panel

The script no longer writes inbounds/clients/hosts into SQLite by hand. After
installing the panel it:

1. seeds `settings` (subscriptions, SNI, certs, web listen) via sqlite3 while the
   panel is stopped, then starts it;
2. mints an admin API token with `x-ui setting -getApiToken true`;
3. calls the panel REST API (`Authorization: Bearer <token>`,
   `https://127.0.0.1:$panel_port/$panel_path/panel/api/...`):
   * `POST /inbounds/add` — all inbounds (JSON bodies built from here-docs);
   * `POST /clients/add` — the eternal client (`expiryTime=0`, `totalGB=0`,
     `flow=xtls-rprx-vision`) attached to every inbound; the panel mints all
     per-protocol credentials itself;
   * `POST /hosts/add` — host groups pinning the public endpoint
     (`<domain>:443` for TLS/REALITY/MTProto inbounds, own ports for UDP ones);
   * `POST /xray/warp/reg` + `POST /xray/update` — WARP registration and the
     outbound/routing merge in the Xray template;
4. `x-ui restart` at the end.

This keeps clients/client_inbounds/client_traffics consistent with the v3 data
model without duplicating its schema.

State (domain, ports, paths, keys, eternal client email/subId) lives in
`/etc/x-ui/3x-ui-pro/install.env` (0600) and is reused by `-patch y`, so
subscription URLs and client credentials survive re-runs.

## Inbounds created

| Tag | Protocol | Port | Transport / security |
|-----|----------|------|----------------------|
| 3x-reality | vless | random loopback | tcp + REALITY (mask SNI) |
| 3x-ws | vless | random loopback | ws, TLS by nginx |
| 3x-grpc | vless | random loopback | grpc, TLS by nginx |
| 3x-httpupgrade | vless | random loopback | httpupgrade, TLS by nginx |
| 3x-xhttp | vless | random loopback | xhttp packet-up, TLS by nginx |
| 3x-kcp | vless | random UDP | kcp |
| 3x-trojan-ws / 3x-trojan-grpc | trojan | random loopback | ws / grpc |
| 3x-vmess-ws / 3x-vmess-grpc | vmess | random loopback | ws / grpc |
| 3x-ss | shadowsocks | random TCP+UDP | 2022-blake3-aes-256-gcm |
| 3x-hysteria | hysteria | **443/udp** | QUIC + TLS, masquerade file |
| 3x-tuic | tuic | random UDP | QUIC sidecar |
| 3x-mtproto | mtproto | random loopback | mtg-multi, FakeTLS SNI via nginx |
| 3x-wireguard | wireguard | random UDP | Xray wireguard |
| 3x-awg | amneziawg | random UDP | in-panel AmneziaWG |

## Running

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/x-ui-latest.sh) \
  -subdomain panel.example.com [-sni bing|google|duckduckgo] [-cover endless|random]

bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/x-ui-patch.sh)
```

AdGuard Home (standalone, re-run safe, `-uninstall y` to remove). AGH binds
localhost only; nginx bridges `/dns-query` (DoH, `allow_unencrypted_doh`) and a
random `/adg-<rand>/` admin path via `snippets/adguard.conf` included in the
panel vhost. Installer/patch regenerate the vhost and drop that include — re-run
this script after them:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main/x-ui-adguard.sh)
```
