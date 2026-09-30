# 3x-ui-pro

🇷🇺 [Русская версия](README.md)

Automated installer for the [3x-ui](https://github.com/MHSanaei/3x-ui) v3+ panel: one domain, every protocol on port 443, an eternal subscription user, endless-loading cover site, WARP egress and a ready RoscomVPN profile for Happ.

- Debian 12/13, Ubuntu 24.04/26.04
- **Single domain** (the second REALITY domain is gone)
- REALITY is masked as **bing / google / duckduckgo** (SNI + fallback to the real site)
- Every TCP protocol on **443** through an nginx SNI router; Hysteria2 on **UDP 443**
- Out of the box the **`eternal` client** — no expiry, no traffic limit, attached to every inbound
- Cover site with an **endless loading screen** (or a random one of 50 sites)
- All client egress through **Cloudflare WARP**
- A [RoscomVPN](https://github.com/hydraponique/roscomvpn-routing) routing profile baked into the JSON subscription for Happ

---

## What gets installed

| Component | Description |
|-----------|-------------|
| 3x-ui | VPN panel with web UI |
| nginx | SNI router on 443 + TLS termination for transports |
| certbot | Let's Encrypt SSL (single domain) |
| Subscriptions | Raw + JSON (Happ) + Clash — the panel's native subscription server |
| Diagnostics | MTR tracer + in-browser speed test (gated by the panel session) |
| Cover site | Endless-loading page (default) |
| WARP | Cloudflare WARP as the egress gateway (registered through the panel API) |
| Backup | Backup / restore script |
| AdGuard Home | Optional: ad-blocking DNS (DoH) — separate script |

---

## Installation

```bash
wget -qO x-ui-latest.sh https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-latest.sh
bash x-ui-latest.sh -subdomain panel.example.com
```

Without `-subdomain` the domain is requested interactively.

> Assets (cover site, diagnostics) are downloaded from this repository. If you forked
> and renamed it, update `tempovichtemp66-byte/3x-ui-pro` in the files or set the environment:
> `XUI_PRO_RAW=https://raw.githubusercontent.com/<you>/<repo>/main bash x-ui-latest.sh ...`.
> The 3x-ui panel itself is still downloaded from the upstream MHSanaei/3x-ui repository.

---

## Inbounds created

### TCP 443 (nginx SNI router)

| Inbound | Transport | How it reaches 443 |
|---------|-----------|--------------------|
| VLESS | REALITY (TCP), `xtls-rprx-vision` flow | masking SNI (`www.bing.com` etc.) |
| VLESS | WebSocket | `/<port>/<random>` path through nginx |
| VLESS | gRPC | `/<port>/<random>` path (HTTP/2 gRPC) |
| VLESS | HTTPUpgrade | `/<port>/<random>` path |
| VLESS | XHTTP `packet-up` | `/<port>/<random>` path |
| Trojan | WebSocket, gRPC | `/<port>/<random>` path |
| VMess | WebSocket, gRPC | `/<port>/<random>` path |
| MTProto | mtg-multi (FakeTLS) | `www.cloudflare.com` SNI through nginx |

### UDP 443

| Inbound | Description |
|---------|-------------|
| Hysteria2 | QUIC, domain certificate, masquerade = the cover site |

### Dedicated ports (cannot share 443)

| Inbound | Transport | Port |
|---------|-----------|------|
| VLESS | mKCP | random UDP |
| TUIC v5 | QUIC | random UDP |
| WireGuard | UDP | random UDP |
| AmneziaWG | UDP | random UDP |
| Shadowsocks-2022 | TCP+UDP | random TCP |

Ports are generated once and stored in `/etc/x-ui/3x-ui-pro/install.env`; re-runs and `x-ui-patch.sh` keep them stable.

---

## Eternal subscription

The installer creates an `eternal` client:

- expiry: **never** (`expiryTime = 0`)
- traffic: **unlimited** (`totalGB = 0`)
- attached to **every** inbound (one subscription — all protocols)
- REALITY links automatically carry `flow=xtls-rprx-vision`

Three subscription URLs are printed:

```
https://<domain>/<path>/eternal        # raw (any client)
https://<domain>/<json-path>/<subid>   # JSON — recommended for Happ (with routing)
https://<domain>/<clash-path>/<subid>  # Clash / Mihomo
```

---

## Masking and cover site

- REALITY clients connect to `<your domain>:443` with SNI `www.bing.com` (or google/duckduckgo) and land on Xray.
- A stranger opening `https://<your domain>` gets an **endless loading page** (a JS progress bar that never reaches 100%).
- Any other SNI is forwarded to the REALITY target, so a scanner sees the real TLS certificate of the chosen site.

Pick the masking SNI:

```bash
bash x-ui-latest.sh -subdomain panel.example.com -sni google
# -sni bing (default), -sni duckduckgo
```

Pick the cover site:

```bash
bash x-ui-latest.sh -subdomain panel.example.com -cover random   # random site out of 50
bash x-ui-latest.sh -subdomain panel.example.com -cover endless  # endless loading (default)
```

---

## WARP egress

The installer registers a Cloudflare WARP device through the panel API and adds to the Xray config:

- a `warp` outbound (WireGuard, `noKernelTun`, IPv4/IPv6);
- routing: private networks → `direct`, everything else → `warp`.

If registration fails the config stays on `direct` (no connectivity loss); enable WARP manually under **Xray → WARP** in the panel.

---

## RoscomVPN routing for Happ

The `subJsonRoutingRules` setting points to the
`hydraponique/roscomvpn-routing` profile (`HAPP/DEFAULT.JSON`): RU/BY direct,
YouTube/Telegram/GitHub and the rest of the world through the proxy, ads blocked.
The panel bakes DNS + routing into every JSON subscription document and sends the
Happ `Routing` header (with the custom geoip/geosite URLs). Import the **JSON
subscription** to get the full profile.

---

## Command-line options

| Option | Description |
|--------|-------------|
| `-subdomain <domain>` | Panel, subscription and cover-site domain |
| `-sni bing\|google\|duckduckgo` | Which site REALITY is masked as (default `bing`) |
| `-cover endless\|random` | Cover site: endless loading or a random site (default `endless`) |
| `-install n` | Skip system package installation (default `y`) |
| `-auto_domain y` | Verify the domain already resolves to this IP |
| `-version <version>` | Install a specific 3x-ui version, default — latest |
| `-uninstall y` | Full uninstall |
| `-patch y` | Re-apply the configuration (used by `x-ui-patch.sh`) |

---

## Patch

Re-applies the current configuration to an existing install **without changing**
the domain, ports, subscription paths or client UUID/passwords (they are read from
`/etc/x-ui/3x-ui-pro/install.env` and the panel DB):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-patch.sh)
```

The patch supports installs created by this version. Moving from the old
two-domain layout is best done with a clean install.

---

## AdGuard Home (optional)

Installs [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) on the panel domain:

- **DNS-over-HTTPS** for clients: `https://<panel-domain>/dns-query`
- **Admin UI** — at a random `/adg-<random>/` path (login and password are printed by the script)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-adguard.sh)
```

Re-running is safe. After the installer or the patch, run this script again — they rewrite the nginx config.

Uninstall:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/x-ui-adguard.sh) -uninstall y
```

---

## Uninstall

```bash
bash x-ui-latest.sh -uninstall y
```

---

## Backup and restore

```bash
wget -qO /usr/local/bin/x-ui-backup https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main/assets/backup/x-ui-backup.sh
chmod +x /usr/local/bin/x-ui-backup

x-ui-backup backup                  # create
x-ui-backup list                    # list
x-ui-backup restore <archive>       # restore
```

The backup includes: nginx configs, panel DB, 3x-ui binary, SSL certificates, web content, systemd units, cron, UFW rules.

---

## Network diagnostics

Available at the link printed by the script (`.../<panel>/diag`), after signing into the panel:

- MTR trace
- Download/upload speed test (LibreSpeed)
- Server information
