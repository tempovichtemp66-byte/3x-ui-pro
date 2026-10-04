#!/bin/bash
#################### 3x-ui-pro (rewritten for 3x-ui v3) #############################
#
# Single-domain 3x-ui installer:
#   * every TCP protocol on :443 behind an nginx SNI router (REALITY is masked
#     as google / bing / duckduckgo, the rest is path-routed over TLS)
#   * Hysteria2 on UDP :443 (QUIC), plus TUIC v5, mKCP, WireGuard, AmneziaWG,
#     Shadowsocks-2022 and MTProto on their own ports
#   * one eternal client (no expiry, no traffic limit) attached to every inbound
#   * endless-loading cover site for strangers, native subscriptions (raw/JSON/Clash)
#   * RoscomVPN routing profile baked into the JSON subscription for Happ
#   * all client egress through Cloudflare WARP (registered via the panel API)
#
# WARNING: educational purposes only. Use only on servers you own and comply
# with the laws of your country. Provided "as is", without warranty — see
# DISCLAIMER.md in the repository.
#
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

# ─── Output helpers ──────────────────────────────────────────────────────────
msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

echo; msg_inf '           ___    _   _   _  '
msg_inf      ' \/ __ | |  | __ |_) |_) / \ '
msg_inf      ' /\    |_| _|_   |   | \ \_/ '; echo
msg_inf "  Только для образовательных целей, на своих серверах / Educational use only, on your own servers."
echo

# ─── Pre-flight checks ───────────────────────────────────────────────────────
check_os() {
    local os_id os_version
    os_id=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"')
    os_version=$(grep -oP '(?<=^VERSION_ID=").+(?=")' /etc/os-release 2>/dev/null)

    case "${os_id}" in
        ubuntu)
            [[ "$os_version" == "24.04" || "$os_version" == "26.04" ]] && return 0
            ;;
        debian)
            [[ "$os_version" == "12" || "$os_version" == "13" ]] && return 0
            ;;
    esac

    msg_err "Unsupported OS: ${os_id} ${os_version}"
    echo -e "\nThis script supports:\n  Ubuntu 24.04 / 26.04\n  Debian 12 / 13"
    echo -e "\nPlease reinstall your server with one of the supported OS versions and try again."
    exit 1
}

check_cpu() {
    local cpu_model
    cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2-)

    if echo "$cpu_model" | grep -qi 'QEMU'; then
        msg_err "QEMU virtual CPU detected!"
        echo -e "\nYour VPS is running with an emulated QEMU processor."
        echo -e "Please contact your hosting provider and ask them to switch the CPU type"
        echo -e "to \e[1;33mhost-passthrough\e[0m (expose real CPU model to the VM)."
        echo -e "\nThis is required for correct operation of the Xray core."
        exit 1
    fi
}

check_os
check_cpu

# ─── Constants ───────────────────────────────────────────────────────────────
XUIDB="/etc/x-ui/x-ui.db"
GITHUB_RAW="${XUI_PRO_RAW:-https://raw.githubusercontent.com/tempovichtemp66-byte/3x-ui-pro/main}"
FAKE_SITE_COUNT=50
STATE_DIR="/etc/x-ui/3x-ui-pro"
STATE_FILE="${STATE_DIR}/install.env"
WORKDIR=$(mktemp -d /tmp/3x-ui-pro.XXXXXX)
METADATA_SNI="www.cloudflare.com"   # MTProto FakeTLS fronting SNI

# ─── Default argument values ─────────────────────────────────────────────────
domain=""
sni="bing"                 # bing | google | duckduckgo | any domain name
cover="endless"            # endless | random
users_arg=""               # -users: how many never-expiring users (default 10)
label=""                   # -label: extra string for connection/subscription names
                            # default when unset: server country (curl ifconfig.co/country)
LABEL_SUFFIX=""            # " [label]" once -label is validated
XRAY_CORE="v26.6.27"        # pinned core: newer cores break REALITY in Mihomo/sing-box
                            # (verified 2026-10-01); pass -xray_core none to keep the bundled one
UNINSTALL="x"
INSTALL="y"
AUTODOMAIN="n"
PATCH="n"
CFALLOW="n"
OPENCODE="n"                 # -opencode y: also install the opencode CLI

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ─── Stop & clean previous install (called from main, after domain validation) ─
clean_previous_install() {
    systemctl stop x-ui 2>/dev/null || true
    rm -rf /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
    rm -rf /etc/nginx/sites-enabled/*
    rm -rf /etc/nginx/sites-available/*
    rm -rf /etc/nginx/stream-enabled/*
}

# ─── Port / path generators ──────────────────────────────────────────────────
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

check_free() {
    nc -z 127.0.0.1 "$1" &>/dev/null
    return $?
}

make_port() {
    while true; do
        local PORT
        PORT=$(get_port)
        if ! check_free "$PORT"; then
            echo "$PORT"
            break
        fi
    done
}

check_free_udp() {
    # -H removes the header row, so the local socket is column 4 (State, Recv-Q, Send-Q, Local, Peer)
    ss -H -lun 2>/dev/null | awk '{print $4}' | grep -q ":$1$"
    return $?
}

make_udp_port() {
    while true; do
        local PORT
        PORT=$(get_port)
        if [[ "$PORT" == "443" ]] || check_free_udp "$PORT"; then
            continue
        fi
        check_free "$PORT" && continue
        echo "$PORT"
        break
    done
}

# WireGuard/AmneziaWG private key. Prefer wg(8); fall back to the panel's own
# xray binary (same Curve25519 key material) when wireguard-tools is absent.
gen_wg_key() {
    if command -v wg >/dev/null 2>&1; then
        wg genkey
        return 0
    fi
    local xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm"
    "$xray_bin" x25519 2>/dev/null | grep '^PrivateKey:' | awk '{print $2}'
}

# REALITY X25519 keypair.
gen_reality_keys() {
    local xray_bin="/usr/local/x-ui/bin/xray-linux-$(_arch)" output
    [[ -f "$xray_bin" ]] || xray_bin="/usr/local/x-ui/bin/xray-linux-arm"
    output=$("$xray_bin" x25519 2>/dev/null)
    reality_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    reality_pub=$(echo "$output"  | grep "^Password"   | awk '{print $3}')
}

# ─── Argument parsing ────────────────────────────────────────────────────────
while [ "$#" -gt 0 ]; do
    case "$1" in
        -install)          INSTALL="$2";    shift 2 ;;
        -subdomain)        domain="$2";     shift 2 ;;
        -sni)              sni="$2";        shift 2 ;;
        -cover)            cover="$2";      shift 2 ;;
        -users)            users_arg="$2";  shift 2 ;;
        -label)            label="$2";      shift 2 ;;
        -xray_core)        XRAY_CORE="$2";  shift 2 ;;
        -ONLY_CF_IP_ALLOW) CFALLOW="$2";    shift 2 ;;
        -opencode)         OPENCODE="$2";     shift 2 ;;
        -version)          PANEL_VERSION="$2"; shift 2 ;;
        -uninstall)        UNINSTALL="$2";  shift 2 ;;
        -patch)            PATCH="$2";      shift 2 ;;
        -auto_domain)      AUTODOMAIN="$2"; shift 2 ;;
        *)                 shift 1 ;;
    esac
done

# ─── Detect package manager ───────────────────────────────────────────────────
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

# ─────────────────────────────────────────────────────────────────────────────
# UNINSTALL
# ─────────────────────────────────────────────────────────────────────────────
uninstall_xui() {
    printf 'y\n' | x-ui uninstall 2>/dev/null || true
    rm -rf /etc/x-ui/ /usr/local/x-ui/
    rm -f  /usr/bin/x-ui
    $Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y purge  nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y autoremove
    $Pak -y autoclean
    rm -rf /var/www/html/ /var/www/diagnostics/ /var/www/subpage/ /etc/nginx/ /usr/share/nginx/
    systemctl stop mtr-backend 2>/dev/null || true
    systemctl disable mtr-backend 2>/dev/null || true
    rm -f /etc/systemd/system/mtr-backend.service
    rm -rf /usr/local/lib/3x-ui-pro/
    systemctl daemon-reload 2>/dev/null || true
}

if [[ ${UNINSTALL} == *"y"* ]]; then
    uninstall_xui
    clear 2>/dev/null || true
    msg_ok "Completely Uninstalled!"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# STATE FILE (ports/paths survive re-runs and -patch)
# ─────────────────────────────────────────────────────────────────────────────
load_state() {
    # shellcheck disable=SC1090
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
}

save_state() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
# generated by 3x-ui-pro, do not edit by hand
DOMAIN='${domain}'
SNI='${sni}'
COVER='${cover}'
LABEL='${label}'
PANEL_PORT='${panel_port}'
PANEL_PATH='${panel_path}'
SUB_PORT='${sub_port}'
SUB_PATH='${sub_path}'
JSON_PATH='${json_path}'
CLASH_PATH='${clash_path}'
REALITY_PORT='${reality_port}'
REALITY_FP='${reality_fp}'
REALITY_KEY='${reality_key}'
REALITY_PUB='${reality_pub}'
WS_PORT='${ws_port}'
WS_PATH='${ws_path}'
GRPC_PORT='${grpc_port}'
GRPC_PATH='${grpc_path}'
HTTPUPGRADE_PORT='${httpupgrade_port}'
HTTPUPGRADE_PATH='${httpupgrade_path}'
XHTTP_PORT='${xhttp_port}'
XHTTP_PATH='${xhttp_path}'
TROJAN_WS_PORT='${trojan_ws_port}'
TROJAN_WS_PATH='${trojan_ws_path}'
TROJAN_GRPC_PORT='${trojan_grpc_port}'
TROJAN_GRPC_PATH='${trojan_grpc_path}'
VMESS_WS_PORT='${vmess_ws_port}'
VMESS_WS_PATH='${vmess_ws_path}'
VMESS_GRPC_PORT='${vmess_grpc_port}'
VMESS_GRPC_PATH='${vmess_grpc_path}'
KCP_PORT='${kcp_port}'
TUIC_PORT='${tuic_port}'
WG_PORT='${wg_port}'
AWG_PORT='${awg_port}'
SS_PORT='${ss_port}'
SS_PASSWORD='${ss_password}'
MTPROTO_PORT='${mtproto_port}'
MTR_PORT='${mtr_backend_port}'
DIAG_PATH='${diag_path}'
DIAG_TOKEN='${diag_token}'
WG_KEY='${wg_key}'
ETERNAL_USERS='${eternal_users}'
CLIENT_BASE='${client_base}'
SUBID_BASE='${subid_base}'
SNI_DOMAIN='${sni_domain}'
EOF
    chmod 600 "$STATE_FILE"
}

# Everything the operator needs, in Markdown: /root/README_PANEL.md (0600).
save_panel_readme() {
    local file="/root/README_PANEL.md" u xray_ver mt_note
    xray_ver=$("$(xray_bin_path)" version 2>/dev/null | awk 'NR==1 {print $2}')
    [[ -n "$MTPROTO_ID" ]] && mt_note=", mtproto" || mt_note=""
    {
        echo "# 3x-ui-pro — доступы и подписки"
        echo
        echo "Создано: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo
        echo "## Панель"
        echo
        echo "- URL: https://${domain}/${panel_path}/"
        echo "- Логин: \`${config_username}\`"
        echo "- Пароль: \`${config_password}\`"
        echo "- Сброс из SSH: \`x-ui setting -username NEW -password NEW && x-ui restart\`"
        echo
        echo "## Сервер"
        echo
        [[ -n "$label" ]] && echo "- Метка: \`${label}\`"
        echo "- Домен: \`${domain}\`"
        echo "- Маскировка REALITY (SNI): \`${sni_domain}\`"
        echo "- Заглушка: \`${cover}\`"
        echo "- Ядро Xray: \`${xray_ver:-unknown}\`"
        echo "- 443/tcp: reality, ws, grpc, httpupgrade, xhttp, trojan, vmess${mt_note}"
        echo "- 443/udp: hysteria2; прочие порты: kcp ${kcp_port}/udp, tuic ${tuic_port}/udp, wireguard ${wg_port}/udp, awg ${awg_port}/udp, ss ${ss_port}/tcp+udp"
        echo "- WARP (исходящий трафик): $( [[ "$WARP_ENABLED" == "true" ]] && echo 'включён' || echo 'ВЫКЛЮЧЕН' )"
        echo "- Диагностика: https://${domain}/${panel_path}/diag (нужен вход в панель)"
        echo
        echo "## Вечные пользователи (${eternal_users} шт., без срока, безлимит)"
        echo
        echo "Пути подписок: \`/${sub_path}/\` — raw, \`/${json_path}/\` — JSON (Happ), \`/${clash_path}/\` — Clash."
        echo "\`subId\` пользователя N: \`${subid_base}-N\`; туннели: \`${subid_base}-N-wg\`, \`${subid_base}-N-awg\`."
        echo
        echo "| # | Happ (JSON) | raw | WireGuard | AmneziaWG (vpn://) |"
        echo "|---|-------------|-----|-----------|--------------------|"
        for ((u = 1; u <= eternal_users; u++)); do
            echo "| ${u} | https://${domain}/${json_path}/${subid_base}-${u} | https://${domain}/${sub_path}/${subid_base}-${u} | https://${domain}/${sub_path}/${subid_base}-${u}-wg | https://${domain}/${sub_path}/${subid_base}-${u}-awg |"
        done
        echo
        echo "> Happ: импортируй JSON-ссылку — вместе с ней приезжает роутинг RoscomVPN."
        echo "> AmneziaVPN: raw-ссылка с суффиксом \`-awg\` (vpn://)."
        echo "> WireGuard в РФ часто режется DPI: если не подключается — не используй, остальные протоколы не затрагивает."
    } > "$file"
    chmod 600 "$file"
}

# ─────────────────────────────────────────────────────────────────────────────
# GET SERVER IP
# ─────────────────────────────────────────────────────────────────────────────
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP6_REGEX="([a-f0-9:]+:+)+[a-f0-9]+"

get_server_ip() {
    IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
    IP6=$(ip route get 2620:fe::fe 2>&1 | grep -Po -- 'src \K\S*')
    [[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')
    [[ $IP6 =~ $IP6_REGEX ]] || IP6=$(curl -s ipv6.icanhazip.com | tr -d '[:space:]')
}

# Early IP fetch for auto-domain
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')

# ─────────────────────────────────────────────────────────────────────────────
# DOMAIN / SNI VALIDATION
# ─────────────────────────────────────────────────────────────────────────────
validate_domains() {
    while true; do
        [[ -n "$domain" ]] && break
        echo -en "Enter available domain (sub.domain.tld): " && read -r domain \
            || { msg_err "No domain provided (use -subdomain panel.example.com)."; exit 1; }
    done
    domain=$(echo "$domain" | tr -d '[:space:]')
    SubDomain=$(echo "$domain"   | sed 's/^[^ ]* \|\..*//g')
    MainDomain=$(echo "$domain"  | sed 's/.*\.\([^.]*\..*\)$/\1/')
    [[ "${SubDomain}.${MainDomain}" != "${domain}" ]] && MainDomain=${domain}

    case "$sni" in
        bing)        sni_domain="www.bing.com" ;;
        google)      sni_domain="www.google.com" ;;
        duckduckgo)  sni_domain="duckduckgo.com" ;;
        "")          sni_domain="www.bing.com" ;;
        *)           sni_domain="$sni" ;;
    esac
    if [[ ! "$sni_domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
        msg_err "Invalid -sni '$sni' (use bing | google | duckduckgo or a domain name)"
        exit 1
    fi

    case "$cover" in
        endless|random) ;;
        *) msg_err "Unsupported -cover '$cover' (use: endless, random)"; exit 1 ;;
    esac

    if [[ -n "$users_arg" ]]; then
        if [[ ! "$users_arg" =~ ^[0-9]+$ ]] || (( users_arg < 1 || users_arg > 100 )); then
            msg_err "Unsupported -users '$users_arg' (expected 1..100)"
            exit 1
        fi
    fi

    # -label: strip shell-hostile characters, collapse whitespace, cap length.
    label="${label//[\'\`\$\"\\]/}"
    label="$(echo "$label" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    label="${label:0:32}"
    if [[ -z "$label" ]]; then
        # default label = the server's country (curl ifconfig.co/country)
        label=$(curl -fsS --max-time 8 https://ifconfig.co/country 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        label="${label//|/}"
        label="${label:0:32}"
    fi
    LABEL_SUFFIX=""
    [[ -n "$label" ]] && LABEL_SUFFIX=" [${label}]"
}

# REALITY steals a real site's TLS handshake, so the masking site has to answer
# with TLS 1.3 and HTTP/2. Check it before wiring it in (same test 3X-UI_KIT uses).
sni_ok() {
    echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -alpn h2 2>/dev/null \
        | grep -q 'ALPN protocol: h2'
}

# mtg talks to Telegram directly; on hosts that block Telegram the proxy would
# be dead weight on port 443, so skip it there.
telegram_reachable() {
    local ip
    for ip in 149.154.167.51 149.154.175.50 91.108.56.130; do
        timeout 5 bash -c "</dev/tcp/$ip/443" 2>/dev/null && return 0
    done
    return 1
}

validate_mask_sni() {
    if sni_ok "$sni_domain"; then
        return 0
    fi
    msg_inf "Masking site ${sni_domain} did not answer with TLS 1.3 + HTTP/2 — picking another..."
    local cand
    for cand in www.bing.com www.google.com duckduckgo.com; do
        if sni_ok "$cand"; then
            sni_domain="$cand"
            sni="$cand"
            msg_inf "Using ${sni_domain} for REALITY masking."
            return 0
        fi
    done
    msg_err "No usable masking site found (TLS 1.3 + HTTP/2 required). Pass a reachable -sni <domain>."
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PACKAGES
# ─────────────────────────────────────────────────────────────────────────────
install_packages() {
    ufw disable 2>/dev/null || true

    if [[ ${INSTALL} == *"y"* ]]; then
        local version
        version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
        [[ "$version" == "20" || "$version" == "22" ]] && echo "System: Ubuntu $version"

        $Pak -y update
        $Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw netcat-openbsd mtr python3 libcap2-bin wireguard-tools openssl qrencode fail2ban
        systemctl daemon-reload && systemctl enable --now nginx
    fi

    apt-get install -yqq --no-install-recommends ca-certificates
}

# ─────────────────────────────────────────────────────────────────────────────
# SSL CERTIFICATES (single domain)
#   The trusted certificate always ends up in /root/cert/<domain>/ so every
#   consumer (nginx, panel, subscription server, hysteria/tuic) uses one path.
#   If Let's Encrypt cannot issue (rate limit, DNS/HTTP-01 problem), a
#   self-signed certificate is generated instead of failing the install;
#   hosts then advertise allowInsecure=1.
# ─────────────────────────────────────────────────────────────────────────────
CERT_SELF_SIGNED="no"

link_le_cert() {
    mkdir -p "/root/cert/${domain}"
    chmod 755 /root/cert
    ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "/root/cert/${domain}/fullchain.pem"
    ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   "/root/cert/${domain}/privkey.pem"
}

get_ssl_certs() {
    systemctl stop nginx 2>/dev/null || true
    fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null || true
    CERT_SELF_SIGNED="no"

    if [[ -d "/etc/letsencrypt/live/${domain}/" ]]; then
        link_le_cert
        return 0
    fi

    if [[ ${AUTODOMAIN} == *"y"* ]]; then
        local a
        a=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
        if [[ "$a" != "$IP4" ]]; then
            msg_err "Auto-domain $domain does not resolve to $IP4. Fix DNS and retry."
            exit 1
        fi
    fi

    certbot certonly --standalone --non-interactive --agree-tos \
        --register-unsafely-without-email -d "$domain" || true
    if [[ -d "/etc/letsencrypt/live/${domain}/" ]]; then
        link_le_cert
        return 0
    fi

    # certbot failed: keep the install alive with a self-signed certificate.
    msg_err "Let's Encrypt certificate for ${domain} could not be issued — using a self-signed one."
    msg_inf "Fix the cause (DNS/port 80/rate limit) and re-run with -patch y to get a trusted certificate."
    rm -rf "/root/cert/${domain}"
    mkdir -p "/root/cert/${domain}"
    chmod 755 /root/cert
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "/root/cert/${domain}/privkey.pem" \
        -out "/root/cert/${domain}/fullchain.pem" \
        -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" -days 3650 2>/dev/null
    chmod 600 "/root/cert/${domain}/privkey.pem"
    CERT_SELF_SIGNED="yes"
    systemctl start nginx >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE NGINX
#   TCP :443 = SNI router (nginx stream module):
#     SNI = mask domain      -> Xray REALITY (127.0.0.1:$reality_port)
#     SNI = our domain       -> nginx https vhost (decoy / panel / subs / transports)
#     SNI = MTProto fronting -> mtg sidecar
#     anything else          -> Xray REALITY (a stranger sees the masked site)
# ─────────────────────────────────────────────────────────────────────────────
configure_nginx() {
    # Drop everything this installer manages before regenerating it (also
    # removes vhosts left behind by the older two-domain layout).
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/*
    rm -f /etc/nginx/stream-enabled/*.conf
    mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets

    # nginx >= 1.25.1 deprecates "listen ... http2" in favor of "http2 on;";
    # older versions (Debian 12 / Ubuntu 24.04) don't know the new directive
    local ngx_ver http2_listen="" http2_on=""
    ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
        http2_on="http2 on;"
    else
        http2_listen=" http2"
    fi

    # ── SNI router ───────────────────────────────────────────────────────────
    # MTProto is routed here only when this host can actually reach Telegram.
    local mt_map_line="" mt_upstream=""
    if [[ "${MT_ON:-yes}" == yes ]]; then
        mt_map_line="    ${METADATA_SNI}       mtproto;"
        mt_upstream="upstream mtproto { server 127.0.0.1:${mtproto_port}; }"
    fi
    cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${sni_domain}         xray;
    ${domain}             www;
${mt_map_line}
    default               xray;
}

upstream xray    { server 127.0.0.1:${reality_port}; }
upstream www     { server 127.0.0.1:7443; }
${mt_upstream}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF

    grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
        || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
    # nginx-full loads the stream module in one of two ways depending on the
    # install: via modules-enabled/50-mod-stream.conf (a symlink — grep -r does
    # not follow those), or not at all. Make sure it is loaded exactly once,
    # whatever a previous run left behind.
    local stream_loaded=no
    if [[ -e /etc/nginx/modules-enabled/50-mod-stream.conf ]]; then
        stream_loaded=yes
    elif grep -Rqs 'ngx_stream_module' /etc/nginx/modules-enabled/ 2>/dev/null; then
        stream_loaded=yes
    fi
    if [[ "$stream_loaded" == yes ]]; then
        # modules-enabled already loads it: drop our own line if an older run added one
        sed -i -E 's|load_module[^;]*ngx_stream_module\.so;[[:space:]]*||g' /etc/nginx/nginx.conf
    elif grep -q 'ngx_stream_module' /etc/nginx/nginx.conf; then
        # not loaded via modules-enabled: self-heal duplicate lines in nginx.conf
        sed -i -E 's|(load_module[^;]*ngx_stream_module\.so;)([[:space:]]*load_module[^;]*ngx_stream_module\.so;)+|\1|g' /etc/nginx/nginx.conf
    else
        sed -i '1s|^|load_module /usr/lib/nginx/modules/ngx_stream_module.so;\n|' /etc/nginx/nginx.conf
    fi
    grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* \
        || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
    sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

    # ── HTTP → HTTPS redirect ────────────────────────────────────────────────
    cat > /etc/nginx/sites-available/80.conf <<EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
EOF

    # ── Shared proxy locations (all Xray path-routed transports) ─────────────
    cat > /etc/nginx/snippets/includes.conf <<EOF
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    location /${sub_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    #Subscription (JSON / Happ)
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    #Subscription (Clash / Mihomo)
    location /${clash_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${clash_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

    #Xray generic proxy: every path looks like /<local_port>/<random>
    #   grpc      -> HTTP/2 gRPC (content-type: application/grpc)
    #   ws        -> Connection: Upgrade / Upgrade: websocket
    #   httpupgrade, xhttp packet-up -> plain POST/GET
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }

    location / { try_files \$uri \$uri/ =404; }
EOF

    # ── Main vhost (TLS termination at 7443 behind the SNI stream) ───────────
    cat > "/etc/nginx/sites-available/${domain}" <<EOF
# Rate limiting zones (http context)
limit_req_zone  \$binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  \$binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone \$binary_remote_addr zone=per_ip:10m;

# Diagnostics access: cookie issued by the SSO bridge after panel login
map \$cookie_diag_key \$diag_auth {
    "${diag_token}" 1;
    default          0;
}

server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl${http2_listen} proxy_protocol;
    listen [::]:7443 ssl${http2_listen} proxy_protocol;
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    # This vhost listens on 7443 behind the SNI stream (public port 443). Without
    # this, nginx bakes :7443 into redirect Location headers (return/error_page),
    # so browsers get sent to an unreachable port. Keep redirects relative.
    absolute_redirect off;
    # Larger h2 preread window improves single-stream upload throughput
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /root/cert/${domain}/fullchain.pem;
    ssl_certificate_key /root/cert/${domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${domain}\$)            { return 444; }
    if (\$scheme ~* https)                          { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location = /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    # ── Diagnostics SSO bridge ───────────────────────────────────────────────
    # Lives under the panel path so the browser attaches the 3x-ui session
    # cookie (its Path is scoped to the panel base path). Valid panel session
    # → issue the diag cookie and redirect; otherwise → panel login page.
    # NOTE: auth_request runs in the access phase; a plain "return" here would
    # skip it (rewrite phase), hence the try_files → named-location hop.
    location = /${panel_path}/diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 /${panel_path}/;
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
        return 302 ${diag_path};
    }
    location = /__diag_auth {
        internal;
        proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # 3x-ui answers AJAX requests with 401 instead of a login redirect
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # auth_request emits a raw 500 to the browser if the subrequest returns
        # anything other than 2xx / 401 / 403 (a login 302, or a 502 when the
        # panel's HTTPS cert is missing). Coerce every such status to a 401 deny
        # so the main location redirects to the panel login instead of 500ing.
        # 401/403 must be listed too, else the server-level "error_page 401 =404"
        # hijacks a genuine deny into a 404 (which auth_request then 500s on).
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # ── Network diagnostics page ─────────────────────────────────────────────
    location ^~ ${diag_path} {
        if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
        limit_req  zone=diag_page burst=10 nodelay;
        limit_conn per_ip 5;
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }

    # ── Diagnostics MTR API ──────────────────────────────────────────────────
    location ^~ ${diag_path}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        limit_req  zone=diag_api burst=2 nodelay;
        limit_conn per_ip 2;
        proxy_pass         http://127.0.0.1:${mtr_backend_port}/api/mtr;
        proxy_http_version 1.1;
        proxy_set_header   X-Real-IP       \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_intercept_errors off;
    }

    # ── LibreSpeed upload sink ───────────────────────────────────────────────
    location ^~ ${diag_path}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        access_log              off;
        limit_conn              per_ip 8;
        proxy_pass              http://127.0.0.1:${mtr_backend_port}/api/st/up;
        proxy_http_version      1.1;
        proxy_set_header        X-Real-IP       \$remote_addr;
        proxy_request_buffering off;
        client_max_body_size    64m;
        proxy_read_timeout      60s;
        proxy_send_timeout      60s;
        add_header              Cache-Control "no-store" always;
    }

    # ── LibreSpeed ping endpoint (answered by nginx, no backend hop) ─────────
    location = ${diag_path}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        access_log off;
        limit_conn per_ip 8;
        add_header Cache-Control "no-store" always;
        default_type text/plain;
        return 200 "";
    }

    # ── LibreSpeed client IP ─────────────────────────────────────────────────
    location = ${diag_path}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/st/getip;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
        add_header          Cache-Control "no-store" always;
    }

    # ── Download test files ──────────────────────────────────────────────────
    location ^~ ${diag_path}testfiles/ {
        if (\$diag_auth = 0) { return 404; }
        alias      /var/www/diagnostics/testfiles/;
        access_log off;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Content-Disposition "attachment" always;
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

    # Activate configs
    if [[ -f "/etc/nginx/sites-available/${domain}" ]]; then
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default /etc/nginx/sites-available/00-maps.conf
        ln -sf "/etc/nginx/sites-available/${domain}" /etc/nginx/sites-enabled/
        ln -sf "/etc/nginx/sites-available/80.conf"   /etc/nginx/sites-enabled/
    else
        msg_err "${domain} nginx config not found!" && exit 1
    fi

    if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
        nginx -t
        msg_err "nginx config check failed!" && exit 1
    fi

    systemctl restart nginx
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL PANEL (3x-ui)
# ─────────────────────────────────────────────────────────────────────────────
_arch() {
    case "$(uname -m)" in
        x86_64|x64|amd64)          echo 'amd64'  ;;
        i*86|x86)                  echo '386'    ;;
        armv8*|armv8|arm64|aarch64) echo 'arm64' ;;
        armv7*|armv7|arm)          echo 'armv7'  ;;
        armv6*|armv6)              echo 'armv6'  ;;
        armv5*|armv5)              echo 'armv5'  ;;
        s390x)                     echo 's390x'  ;;
        *) echo "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

_panel_initial_config() {
    /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
    /usr/local/x-ui/x-ui migrate
}

install_panel() {
    local tag_version
    apt-get update && apt-get install -y -q wget curl tar tzdata

    cd /usr/local/

    if [[ -n "$PANEL_VERSION" ]]; then
        tag_version="v${PANEL_VERSION#v}"
        if ! curl -fsLo /dev/null "https://api.github.com/repos/MHSanaei/3x-ui/releases/tags/${tag_version}" \
           && ! curl -4 -fsLo /dev/null "https://api.github.com/repos/MHSanaei/3x-ui/releases/tags/${tag_version}"; then
            echo "3x-ui release ${tag_version} not found." && exit 1
        fi
    else
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
            | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        if [[ ! "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" \
                | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
        fi
        if [[ ! "$tag_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Failed to fetch 3x-ui version." && exit 1
        fi
    fi

    echo "Installing 3x-ui ${tag_version} ..."
    wget -N -O /usr/local/x-ui-linux-$(_arch).tar.gz \
        "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(_arch).tar.gz"
    [[ $? -ne 0 ]] && echo "Download failed." && exit 1

    wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    [[ $? -ne 0 ]] && echo "Failed to download x-ui.sh" && exit 1

    [[ -d /usr/local/x-ui/ ]] && systemctl stop x-ui 2>/dev/null; rm -rf /usr/local/x-ui/

    tar zxvf x-ui-linux-$(_arch).tar.gz
    rm -f x-ui-linux-$(_arch).tar.gz

    cd x-ui
    chmod +x x-ui x-ui.sh

    if [[ $(_arch) == "armv5" || $(_arch) == "armv6" || $(_arch) == "armv7" ]]; then
        mv bin/xray-linux-$(_arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x bin/xray-linux-$(_arch)

    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    _panel_initial_config

    cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui

    # This installer drives the whole setup through the v3 panel API, so refuse
    # to run on an older (v2) core where those endpoints do not exist.
    local panel_ver
    panel_ver=$(/usr/local/x-ui/x-ui -v 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$panel_ver" && "${panel_ver%%.*}" -lt 3 ]]; then
        msg_err "3x-ui ${panel_ver} is too old for this installer (v3+ required)."
        msg_err "Run without -version to install the latest release."
        exit 1
    fi

    msg_ok "3x-ui ${tag_version} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# PANEL SETTINGS (seeded through sqlite while the panel is stopped)
# ─────────────────────────────────────────────────────────────────────────────
sql_set() {
    printf 'DELETE FROM "settings" WHERE "key"='"'"'%s'"'"';\n' "$1"
    printf 'INSERT INTO "settings" ("key","value") VALUES ('"'"'%s'"'"','"'"'%s'"'"');\n' "$1" "$2"
}

configure_panel_settings() {
    x-ui stop 2>/dev/null || true

    /usr/local/x-ui/x-ui setting \
        -username  "${config_username}" \
        -password  "${config_password}" \
        -port      "${panel_port}"      \
        -webBasePath "${panel_path}"

    /usr/local/x-ui/x-ui cert \
        -webCert    "/root/cert/${domain}/fullchain.pem" \
        -webCertKey "/root/cert/${domain}/privkey.pem"

    local sub_uri="https://${domain}/${sub_path}/"
    local json_uri="https://${domain}/${json_path}/"
    local clash_uri="https://${domain}/${clash_path}/"
    local routing_url="https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-routing@main/HAPP/DEFAULT.JSON"

    {
        sql_set subEnable        'true'
        sql_set subEncrypt       'true'
        sql_set subShowInfo      'true'
        sql_set subUpdates       '12'
        sql_set subPort          "${sub_port}"
        sql_set subPath          "/${sub_path}/"
        sql_set subURI           "${sub_uri}"
        sql_set subJsonEnable    'true'
        sql_set subJsonPath      "/${json_path}/"
        sql_set subJsonURI       "${json_uri}"
        sql_set subJsonRules     ''
        sql_set subJsonRoutingRules "${routing_url}"
        sql_set subClashEnable   'true'
        sql_set subClashPath     "/${clash_path}/"
        sql_set subClashURI      "${clash_uri}"
        sql_set subClashAutoDetect 'true'
        sql_set subDomain        "${domain}"
        sql_set subListen        '127.0.0.1'
        sql_set subCertFile      "/root/cert/${domain}/fullchain.pem"
        sql_set subKeyFile       "/root/cert/${domain}/privkey.pem"
        sql_set webListen        '127.0.0.1'
        sql_set webDomain        ''
        sql_set sessionMaxAge    '60'
        sql_set pageSize         '50'
        sql_set expireDiff       '0'
        sql_set trafficDiff      '0'
        sql_set remarkModel      '-ieo'
        sql_set timeLocation     'Europe/Moscow'
        sql_set datepicker       'gregorian'
        sql_set tgBotEnable      'false'
        sql_set tgLang           'en-US'
        sql_set tgCpu            '80'
        sql_set tgRunTime        '@daily'
    } | sqlite3 "$XUIDB"

    x-ui start
}

# ─────────────────────────────────────────────────────────────────────────────
# PANEL API HELPERS
# ─────────────────────────────────────────────────────────────────────────────
PANEL_BASE=""
API_TOKEN=""

api() { # api <METHOD> <path> [extra curl args...]
    local method="$1" path="$2"
    shift 2
    curl -sk --max-time 90 -X "$method" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "${PANEL_BASE}/panel/api${path}" "$@"
}

api_ok() {
    jq -e '.success == true' >/dev/null 2>&1
}

wait_for_panel() {
    local i
    for i in $(seq 1 90); do
        if curl -sk --max-time 3 -o /dev/null "https://127.0.0.1:${panel_port}/${panel_path}/"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

init_api() {
    PANEL_BASE="https://127.0.0.1:${panel_port}/${panel_path}"

    wait_for_panel || { msg_err "Panel did not come up on port ${panel_port}."; exit 1; }

    API_TOKEN=""
    local i out
    for i in 1 2 3 4 5; do
        # NOTE: /usr/bin/x-ui is the panel's shell wrapper and does not forward
        # the `setting` subcommand — call the real binary directly.
        out=$(/usr/local/x-ui/x-ui setting -getApiToken true 2>&1)
        API_TOKEN=$(echo "$out" | sed -n 's/^apiToken: *//p' | tail -n1)
        [[ -n "$API_TOKEN" ]] && break
        sleep 2
    done
    if [[ -z "$API_TOKEN" ]]; then
        msg_err "Failed to mint a panel API token. CLI output:"
        echo "$out"
        exit 1
    fi

    if ! api GET /server/status | api_ok; then
        msg_err "Panel API token rejected — check the panel version."
        exit 1
    fi
}

# Xray binary of the installed panel (install_panel renames armv5/6/7 builds).
xray_bin_path() {
    local b="/usr/local/x-ui/bin/xray-linux-$(_arch)"
    [[ -f "$b" ]] || b="/usr/local/x-ui/bin/xray-linux-arm"
    echo "$b"
}

# Optional core pin (-xray_core v26.6.27). Xray cores newer than 26.6.x broke
# REALITY for non-Xray clients (Mihomo/sing-box), so the installer can install
# a version verified against every client via the panel API.
ensure_xray_core() {
    [[ -n "$XRAY_CORE" && "$XRAY_CORE" != "none" ]] || return 0
    local want="${XRAY_CORE#v}" cur i
    cur=$("$(xray_bin_path)" version 2>/dev/null | awk 'NR==1 {print $2}')
    if [[ "$cur" == "$want" ]]; then
        msg_inf "Xray core v${cur} already installed."
        return 0
    fi
    msg_inf "Installing Xray core v${want} (client compatibility)..."
    api POST "/server/installXray/v${want}" -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    for i in $(seq 1 60); do
        sleep 2
        cur=$("$(xray_bin_path)" version 2>/dev/null | awk 'NR==1 {print $2}')
        [[ "$cur" == "$want" ]] && break
    done
    if [[ "$cur" == "$want" ]]; then
        msg_ok "Xray core v${want} installed."
    else
        msg_err "Failed to install Xray core v${want} (current: ${cur:-unknown})."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INBOUNDS
# ─────────────────────────────────────────────────────────────────────────────
ALL_IDS=()

json_file() { local f="${WORKDIR}/$1"; : > "$f"; echo "$f"; }

delete_managed_inbounds() {
    local ids
    ids=$(api GET /inbounds/list | jq -r '.obj[]? | select(.tag | startswith("3x-")) | .id')
    [[ -z "$ids" ]] && return 0
    local id
    for id in $ids; do
        api POST "/inbounds/del/${id}" >/dev/null
        msg_inf "Removed old managed inbound ${id}"
    done
}

add_inbound() { # add_inbound <tag> <payload-file> — prints the new inbound id on stdout
    local tag="$1" file="$2" resp id
    resp=$(api POST /inbounds/add -H 'Content-Type: application/json' --data-binary "@${file}")
    if echo "$resp" | api_ok; then
        id=$(echo "$resp" | jq -r '.obj.id')
        msg_ok "Inbound '${tag}' created (id ${id})" >&2
        echo "$id"
    else
        msg_err "Failed to create inbound '${tag}': $(echo "$resp" | jq -r '.msg // "unknown error"')" >&2
        echo ""
    fi
}

install_inbounds() {
    local resp f id

    # ── REALITY keys ─────────────────────────────────────────────────────────
    if [[ -z "${reality_key}" || -z "${reality_pub}" ]]; then
        gen_reality_keys
    fi

    local short
    short=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) \
           $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

    local sniff_off='{"enabled":false,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'
    local sniff_on='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

    # ── 1. VLESS + REALITY (masked as ${sni_domain}) ─────────────────────────
    f=$(json_file reality.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ reality",
  "listen": "127.0.0.1",
  "port": ${reality_port},
  "protocol": "vless",
  "tag": "3x-reality",
  "settings": {"clients": [], "decryption": "none", "encryption": "none", "fallbacks": []},
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 0,
      "target": "${sni_domain}:443",
      "serverNames": ["${sni_domain}"],
      "privateKey": "${reality_key}",
      "minClientVer": "",
      "maxClientVer": "",
      "maxTimediff": 0,
      "shortIds": [
        "${short[0]}","${short[1]}","${short[2]}","${short[3]}",
        "${short[4]}","${short[5]}","${short[6]}","${short[7]}"
      ],
      "settings": {
        "publicKey": "${reality_pub}",
        "fingerprint": "${reality_fp}",
        "serverName": "",
        "spiderX": "/"
      }
    },
    "tcpSettings": {
      "acceptProxyProtocol": true,
      "header": {"type": "none"}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-reality" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); REALITY_ID="$id"

    # ── 2. VLESS + WebSocket ─────────────────────────────────────────────────
    f=$(json_file ws.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ ws",
  "listen": "127.0.0.1",
  "port": ${ws_port},
  "protocol": "vless",
  "tag": "3x-ws",
  "settings": {"clients": [], "decryption": "none", "encryption": "none", "fallbacks": []},
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "acceptProxyProtocol": false,
      "path": "/${ws_port}/${ws_path}",
      "host": "${domain}",
      "headers": {}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-ws" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); WS_ID="$id"

    # ── 3. VLESS + gRPC ──────────────────────────────────────────────────────
    f=$(json_file grpc.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ grpc",
  "listen": "127.0.0.1",
  "port": ${grpc_port},
  "protocol": "vless",
  "tag": "3x-grpc",
  "settings": {"clients": [], "decryption": "none", "encryption": "none", "fallbacks": []},
  "streamSettings": {
    "network": "grpc",
    "security": "none",
    "grpcSettings": {
      "serviceName": "/${grpc_port}/${grpc_path}",
      "authority": "${domain}",
      "multiMode": false
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-grpc" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); GRPC_ID="$id"

    # ── 4. VLESS + HTTPUpgrade ───────────────────────────────────────────────
    f=$(json_file httpupgrade.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ httpupgrade",
  "listen": "127.0.0.1",
  "port": ${httpupgrade_port},
  "protocol": "vless",
  "tag": "3x-httpupgrade",
  "settings": {"clients": [], "decryption": "none", "encryption": "none", "fallbacks": []},
  "streamSettings": {
    "network": "httpupgrade",
    "security": "none",
    "httpupgradeSettings": {
      "acceptProxyProtocol": false,
      "path": "/${httpupgrade_port}/${httpupgrade_path}",
      "host": "${domain}",
      "headers": {}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-httpupgrade" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); HTTPUPGRADE_ID="$id"

    # ── 5. VLESS + XHTTP (packet-up, HTTP/1.1-friendly) ──────────────────────
    f=$(json_file xhttp.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ xhttp",
  "listen": "127.0.0.1",
  "port": ${xhttp_port},
  "protocol": "vless",
  "tag": "3x-xhttp",
  "settings": {"clients": [], "decryption": "none", "encryption": "none", "fallbacks": []},
  "streamSettings": {
    "network": "xhttp",
    "security": "none",
    "xhttpSettings": {
      "path": "/${xhttp_port}/${xhttp_path}",
      "host": "${domain}",
      "headers": {},
      "mode": "packet-up",
      "noGRPCHeader": true,
      "xPaddingBytes": "100-1000",
      "scMaxBufferedPosts": 30
    }
  },
  "sniffing": ${sniff_on}
}
EOF
    id=$(add_inbound "3x-xhttp" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); XHTTP_ID="$id"

    # ── 6. VLESS + mKCP (own UDP port) ───────────────────────────────────────
    # Xray-core v26 refuses plain VLESS without transport TLS (only private
    # addresses are exempt), so mKCP carries VLESS-level encryption instead.
    local kcp_dec="none" kcp_enc="none" vless_enc
    vless_enc=$(api GET /server/getNewVlessEnc)
    if echo "$vless_enc" | api_ok; then
        kcp_dec=$(echo "$vless_enc" | jq -r '[.obj.auths[]? | select(.id == "x25519")][0].decryption // empty')
        kcp_enc=$(echo "$vless_enc" | jq -r '[.obj.auths[]? | select(.id == "x25519")][0].encryption // empty')
        [[ -n "$kcp_dec" && -n "$kcp_enc" ]] || { kcp_dec="none"; kcp_enc="none"; }
    fi
    f=$(json_file kcp.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ kcp",
  "listen": "",
  "port": ${kcp_port},
  "protocol": "vless",
  "tag": "3x-kcp",
  "settings": {"clients": [], "decryption": "${kcp_dec}", "encryption": "${kcp_enc}"},
  "streamSettings": {
    "network": "kcp",
    "security": "none",
    "kcpSettings": {
      "mtu": 1350,
      "tti": 20,
      "uplinkCapacity": 5,
      "downlinkCapacity": 20,
      "cwndMultiplier": 1,
      "maxSendingWindow": 2097152
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-kcp" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); KCP_ID="$id"

    # ── 7. Trojan + WebSocket ────────────────────────────────────────────────
    f=$(json_file trojan_ws.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ trojan-ws",
  "listen": "127.0.0.1",
  "port": ${trojan_ws_port},
  "protocol": "trojan",
  "tag": "3x-trojan-ws",
  "settings": {"clients": [], "fallbacks": []},
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "acceptProxyProtocol": false,
      "path": "/${trojan_ws_port}/${trojan_ws_path}",
      "host": "${domain}",
      "headers": {}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-trojan-ws" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); TROJAN_WS_ID="$id"

    # ── 8. Trojan + gRPC ─────────────────────────────────────────────────────
    f=$(json_file trojan_grpc.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ trojan-grpc",
  "listen": "127.0.0.1",
  "port": ${trojan_grpc_port},
  "protocol": "trojan",
  "tag": "3x-trojan-grpc",
  "settings": {"clients": [], "fallbacks": []},
  "streamSettings": {
    "network": "grpc",
    "security": "none",
    "grpcSettings": {
      "serviceName": "/${trojan_grpc_port}/${trojan_grpc_path}",
      "authority": "${domain}",
      "multiMode": false
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-trojan-grpc" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); TROJAN_GRPC_ID="$id"

    # ── 9. VMess + WebSocket ─────────────────────────────────────────────────
    f=$(json_file vmess_ws.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ vmess-ws",
  "listen": "127.0.0.1",
  "port": ${vmess_ws_port},
  "protocol": "vmess",
  "tag": "3x-vmess-ws",
  "settings": {"clients": []},
  "streamSettings": {
    "network": "ws",
    "security": "none",
    "wsSettings": {
      "acceptProxyProtocol": false,
      "path": "/${vmess_ws_port}/${vmess_ws_path}",
      "host": "${domain}",
      "headers": {}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-vmess-ws" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); VMESS_WS_ID="$id"

    # ── 10. VMess + gRPC ─────────────────────────────────────────────────────
    f=$(json_file vmess_grpc.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ vmess-grpc",
  "listen": "127.0.0.1",
  "port": ${vmess_grpc_port},
  "protocol": "vmess",
  "tag": "3x-vmess-grpc",
  "settings": {"clients": []},
  "streamSettings": {
    "network": "grpc",
    "security": "none",
    "grpcSettings": {
      "serviceName": "/${vmess_grpc_port}/${vmess_grpc_path}",
      "authority": "${domain}",
      "multiMode": false
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-vmess-grpc" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); VMESS_GRPC_ID="$id"

    # ── 11. Shadowsocks-2022 (own TCP/UDP port) ──────────────────────────────
    f=$(json_file ss.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ ss-2022",
  "listen": "",
  "port": ${ss_port},
  "protocol": "shadowsocks",
  "tag": "3x-ss",
  "settings": {
    "method": "2022-blake3-aes-256-gcm",
    "password": "${ss_password}",
    "network": "tcp,udp",
    "clients": [],
    "ivCheck": false
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-ss" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); SS_ID="$id"

    # ── 12. Hysteria2 (UDP :443, masquerades as the cover site) ──────────────
    f=$(json_file hysteria.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ hysteria2",
  "listen": "",
  "port": 443,
  "protocol": "hysteria",
  "tag": "3x-hysteria",
  "settings": {"version": 2, "clients": []},
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
      "serverName": "${domain}",
      "minVersion": "1.2",
      "maxVersion": "1.3",
      "certificates": [
        {
          "certificateFile": "/root/cert/${domain}/fullchain.pem",
          "keyFile": "/root/cert/${domain}/privkey.pem",
          "ocspStapling": 0,
          "oneTimeLoading": false,
          "usage": "encipherment",
          "buildChain": false
        }
      ],
      "alpn": ["h3"]
    },
    "hysteriaSettings": {
      "version": 2,
      "udpIdleTimeout": 60,
      "masquerade": {"type": "file", "dir": "/var/www/html"}
    }
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-hysteria" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); HYSTERIA_ID="$id"

    # ── 13. TUIC v5 (own UDP port) ───────────────────────────────────────────
    f=$(json_file tuic.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ tuic-v5",
  "listen": "",
  "port": ${tuic_port},
  "protocol": "tuic",
  "tag": "3x-tuic",
  "settings": {
    "certificate": "/root/cert/${domain}/fullchain.pem",
    "private_key": "/root/cert/${domain}/privkey.pem",
    "congestion_control": "bbr",
    "alpn": ["h3"],
    "udp_relay_mode": "native",
    "zero_rtt_handshake": true,
    "log_level": "info",
    "sni": "${domain}",
    "clients": []
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-tuic" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); TUIC_ID="$id"

    # ── 14. MTProto (mtg-multi, fronted through nginx :443 by FakeTLS SNI) ───
    if [[ "${MT_ON:-yes}" == yes ]]; then
    f=$(json_file mtproto.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ mtproto",
  "listen": "127.0.0.1",
  "port": ${mtproto_port},
  "protocol": "mtproto",
  "tag": "3x-mtproto",
  "settings": {
    "fakeTlsDomain": "${METADATA_SNI}",
    "clients": [],
    "proxyProtocolListener": true
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-mtproto" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); MTPROTO_ID="$id"
    else
        msg_inf "MTProto inbound skipped (Telegram unreachable from this host)."
    fi

    # ── 15. WireGuard (own UDP port) ─────────────────────────────────────────
    f=$(json_file wireguard.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ wireguard",
  "listen": "",
  "port": ${wg_port},
  "protocol": "wireguard",
  "tag": "3x-wireguard",
  "settings": {
    "mtu": ${WARP_TUN_MTU:-1420},
    "secretKey": "${wg_key}",
    "peers": [],
    "clients": []
  },
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-wireguard" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); WG_ID="$id"

    # ── 16. AmneziaWG (own UDP port) ─────────────────────────────────────────
    # Empty settings: the panel generates a fresh randomized AmneziaWG 3.1
    # obfuscation set (Jc/Jmin/Jmax, S1-S4, H1-H4, I1, HeaderProtectionKey,
    # timings, RandomTrailers/DisableCookies) plus the server keypair — the same
    # path the UI uses for new inbounds. Clients need AmneziaWG 3.1 support
    # (recent AmneziaVPN); every generated parameter is mirrored into the
    # subscription's vpn:// config.
    f=$(json_file amneziawg.json)
    cat > "$f" <<EOF
{
  "enable": true,
  "remark": "⚡ amneziawg",
  "listen": "",
  "port": ${awg_port},
  "protocol": "amneziawg",
  "tag": "3x-awg",
  "settings": {},
  "sniffing": ${sniff_off}
}
EOF
    id=$(add_inbound "3x-awg" "$f"); [[ -n "$id" ]] || exit 1
    ALL_IDS+=("$id"); AWG_ID="$id"
}

# ─────────────────────────────────────────────────────────────────────────────
# ETERNAL CLIENT + HOSTS
# ─────────────────────────────────────────────────────────────────────────────
create_eternal_client() { # <email> <subid> <inbound-ids-csv> [flow]
    local email="$1" subid="$2" ids_csv="$3" flow="${4:-}"
    local payload="${WORKDIR}/client-${email}.json" resp
    local ids_json
    ids_json=$(echo "$ids_csv" | tr ',' '\n' | grep -v '^$' | jq -R 'tonumber' | jq -s -c '.')
    cat > "$payload" <<EOF
{
  "client": {
    "email": "${email}",
    "subId": "${subid}",
    "totalGB": 0,
    "expiryTime": 0,
    "enable": true,
    "limitIp": 0,
    "flow": "${flow}",
    "comment": "3x-ui-pro eternal subscription (no expiry, unlimited)"
  },
  "inboundIds": ${ids_json}
}
EOF
    resp=$(api POST /clients/add -H 'Content-Type: application/json' --data-binary "@${payload}")
    if echo "$resp" | api_ok; then
        msg_inf "Eternal client '${email}' created."
    else
        msg_err "Failed to create client '${email}': $(echo "$resp" | jq -r '.msg // "unknown error"')"
        exit 1
    fi
}

install_eternal_users() {
    # One client per user for the xray-handled inbounds, plus one client per
    # user for each tunnel protocol: the panel keeps a single WireGuard keypair
    # and tunnel address per client row, so sharing one identity across
    # WireGuard and AmneziaWG would advertise the wrong keys for one of them.
    local main_ids="" i u
    for i in "${ALL_IDS[@]}"; do
        [[ "$i" == "$WG_ID" || "$i" == "$AWG_ID" ]] && continue
        main_ids+="${i},"
    done
    main_ids="${main_ids%,}"

    for ((u = 1; u <= eternal_users; u++)); do
        create_eternal_client "${client_base}-${u}"     "${subid_base}-${u}"     "${main_ids}" "xtls-rprx-vision"
        create_eternal_client "${client_base}-${u}-wg"  "${subid_base}-${u}-wg"  "${WG_ID}"    ""
        create_eternal_client "${client_base}-${u}-awg" "${subid_base}-${u}-awg" "${AWG_ID}"   ""
    done
    msg_ok "${eternal_users} eternal user(s) created (no expiry, unlimited)."
}

delete_managed_hosts() {
    local groups gid
    groups=$(api GET /hosts/list | jq -r --arg d "$domain" '.obj[]? | select((.hosts[0] // "") | startswith($d)) | .groupId')
    [[ -z "$groups" ]] && return 0
    for gid in $groups; do
        api POST "/hosts/del/${gid}" >/dev/null
    done
}

add_host_group() { # add_host_group <remark> <ids-csv> <address:port> <security> <sni> [alpn-csv] [allow-insecure] [pins-csv]
    local remark="$1" ids_csv="$2" endpoint="$3" security="$4" hsni="$5" alpn_csv="${6:-}" insecure="${7:-no}" pins_csv="${8:-}"
    local payload="${WORKDIR}/host.json" resp
    local ids_json alpn_json="[]" insecure_json="false" pins_json="[]"
    ids_json=$(echo "$ids_csv" | tr ',' '\n' | jq -R 'tonumber' | jq -s -c '.')
    [[ -n "$alpn_csv" ]] && alpn_json=$(echo "$alpn_csv" | tr ',' '\n' | jq -R . | jq -s -c '.')
    [[ "$insecure" == yes ]] && insecure_json="true"
    [[ -n "$pins_csv" ]] && pins_json=$(echo "$pins_csv" | tr ',' '\n' | jq -R . | jq -s -c '.')
    cat > "$payload" <<EOF
{
  "inboundIds": ${ids_json},
  "hosts": ["${endpoint}"],
  "remark": "${remark}",
  "sortOrder": 0,
  "security": "${security}",
  "sni": "${hsni}",
  "fingerprint": "firefox",
  "allowInsecure": ${insecure_json},
  "pinnedPeerCertSha256": ${pins_json},
  "alpn": ${alpn_json}
}
EOF
    resp=$(api POST /hosts/add -H 'Content-Type: application/json' --data-binary "@${payload}")
    if echo "$resp" | api_ok; then
        msg_ok "Host group '${remark}' -> ${endpoint}"
    else
        msg_err "Failed to add host group '${remark}': $(echo "$resp" | jq -r '.msg // "unknown error"')"
    fi
}

install_hosts() {
    # With a self-signed certificate (Let's Encrypt unavailable) TLS links must
    # carry the certificate pin — xray-core v26 removed allowInsecure, so a pin
    # is the only way clients can trust our own certificate. REALITY needs
    # neither (it never verifies the peer certificate).
    local insec="no" pin=""
    if [[ "$CERT_SELF_SIGNED" == yes ]]; then
        insec="yes"
        pin=$(openssl x509 -in "/root/cert/${domain}/fullchain.pem" -outform der \
              | openssl dgst -sha256 -binary | base64 -w0)
    fi
    # REALITY keeps its own TLS params; only the public address/port is
    # overridden. No host SNI: with one set, the panel injects
    # realitySettings.serverNames into the JSON subscription client configs,
    # and xray-core v26 clients reject that field (they want serverName).
    # The link still gets its SNI from the inbound's own serverNames.
    add_host_group " " "$REALITY_ID" "${domain}:443" "same" "" "" "no" ""
    # ALPN must match the transport: WebSocket/HTTPUpgrade speak HTTP/1.1,
    # gRPC needs h2, XHTTP accepts both. A wrong ALPN makes nginx translate the
    # protocol and the xray inbound drops the connection.
    add_host_group " " \
        "$WS_ID,$TROJAN_WS_ID,$VMESS_WS_ID,$HTTPUPGRADE_ID" "${domain}:443" "tls" "" "http/1.1" "$insec" "$pin"
    add_host_group " " \
        "$GRPC_ID,$TROJAN_GRPC_ID,$VMESS_GRPC_ID" "${domain}:443" "tls" "" "h2" "$insec" "$pin"
    add_host_group " " \
        "$XHTTP_ID" "${domain}:443" "tls" "" "h2,http/1.1" "$insec" "$pin"
    # UDP / sidecar protocols advertise their own ports.
    add_host_group " " "$HYSTERIA_ID" "${domain}:443" "tls" "${domain}" "" "$insec" "$pin"
    add_host_group " "      "$KCP_ID"      "${domain}:${kcp_port}" "none" "" "" "no" ""
    add_host_group " "     "$TUIC_ID"     "${domain}:${tuic_port}" "tls" "${domain}" "" "$insec" "$pin"
    add_host_group " "       "$SS_ID"       "${domain}:${ss_port}" "none" "" "" "no" ""
    add_host_group " " "$WG_ID"      "${domain}:${wg_port}" "none" "" "" "no" ""
    add_host_group " "      "$AWG_ID"      "${domain}:${awg_port}" "none" "" "" "no" ""
    [[ -n "$MTPROTO_ID" ]] && add_host_group " " "$MTPROTO_ID" "${domain}:443" "none" "" "" "no" ""
}

# ─────────────────────────────────────────────────────────────────────────────
# WARP PATH MTU DETECTION
# ─────────────────────────────────────────────────────────────────────────────
# The WireGuard tunnel's MTU must fit the outer packet (tunnel MTU + 44 bytes
# of IPv4 overhead: 20 IP + 8 UDP + 16 WireGuard) into the path MTU towards
# the WARP endpoint. Many providers cap the path below 1500 (AEZA: 1448), so
# the old hardcoded 1420 silently dropped every full-size tunnel packet and
# every client request took 5-10s. Probe with ICMP (ping -M do) and clamp the
# tunnel MTU to [1280, 1420].
#
# The WARP anycast answers differently per address family: some providers
# anchor IPv6 at a far-away POP (AEZA: ~7ms v4 vs ~45ms v6) and the IPv6 data
# path can be lossy, so the tunnel prefers the IPv4 endpoint. The tunnel MTU
# is sized so the IPv6 path fits too (64B vs 44B overhead) — harmless and safe.
# AI sites (google/openai) are routed direct instead of WARP: Cloudflare's
# IPv4 WARP range (104.28.x.x) is flagged as VPN by Google/OpenAI, while a
# hosting IP is not.
# ─────────────────────────────────────────────────────────────────────────────
WARP_EP_HOST="${WARP_EP_HOST:-engage.cloudflareclient.com}"
WARP_TUN_MTU=""
WARP_DOMAIN_STRATEGY="ForceIPv4v6"

detect_warp_pmtu() {
    local host="$1" v4 v6 probe ipver size pmtu overhead mtu
    v4=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    v6=$(getent ahostsv6 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ -n "$v4" ]]; then
        WARP_DOMAIN_STRATEGY="ForceIPv4"
        probe="$v4"; ipver=4
    elif [[ -n "$v6" ]]; then
        probe="$v6"; ipver=6
    else
        msg_inf "WARP endpoint ${host} did not resolve — keeping default MTU 1420."
        WARP_TUN_MTU=1420
        return 0
    fi

    pmtu=1500
    if command -v ping >/dev/null 2>&1; then
        local found=0
        for size in 1472 1448 1420 1380 1340 1300 1252; do
            if ping -"$ipver" -c 1 -W 2 -M do -s "$size" "$probe" >/dev/null 2>&1; then
                if [[ "$ipver" == "6" ]]; then pmtu=$((size + 48)); else pmtu=$((size + 28)); fi
                found=1
                break
            fi
        done
        # ICMP fully blocked: assume the worst instead of guessing 1500.
        (( found )) || pmtu=1280
    fi

    # IPv6-safe: 64B overhead + 12B safety margin (44B for IPv4 alone would leave
    # the IPv6 path oversize and silently break IPv6 egress inside the tunnel).
    overhead=76
    mtu=$((pmtu - overhead))
    (( mtu < 1280 )) && mtu=1280
    (( mtu > 1420 )) && mtu=1420
    WARP_TUN_MTU=$mtu
    msg_inf "WARP path MTU to ${probe}: ${pmtu} B -> tunnel MTU ${WARP_TUN_MTU} (${WARP_DOMAIN_STRATEGY})."
}

# WARP EGRESS (Cloudflare WARP registered through the panel API)
# ─────────────────────────────────────────────────────────────────────────────
configure_warp() {
    local data_raw cfg_raw warp_out reserved v4 v6 has_warp reg
    local wg_priv wg_pub

    data_raw=$(api POST /xray/warp/data | jq -r '.obj // empty' 2>/dev/null)

    local reg_ok=false
    if [[ -n "$data_raw" ]] && echo "$data_raw" | jq -e '.private_key and .access_token' >/dev/null 2>&1; then
        # Already registered (re-run / patch): reuse the stored credentials.
        wg_priv=$(echo "$data_raw" | jq -r '.private_key')
        cfg_raw=$(api POST /xray/warp/config | jq -c '.obj | if type=="string" then (fromjson? // empty) else . end' 2>/dev/null)
        [[ -n "$cfg_raw" ]] && reg_ok=true
    else
        wg_priv=$(gen_wg_key)
        wg_pub=$(printf '%s' "$wg_priv" | wg pubkey 2>/dev/null)
        [[ -n "$wg_pub" ]] || wg_pub=$(printf '%s' "$wg_priv" | /usr/local/x-ui/bin/xray-linux-$(_arch) x25519 2>/dev/null | grep '^Password' | awk '{print $3}')
        reg=$(curl -sk --max-time 30 -X POST \
            -H "Authorization: Bearer ${API_TOKEN}" \
            --data-urlencode "privateKey=${wg_priv}" \
            --data-urlencode "publicKey=${wg_pub}" \
            "${PANEL_BASE}/panel/api/xray/warp/reg")
        if echo "$reg" | api_ok; then
            cfg_raw=$(echo "$reg" | jq -c '.obj | if type=="string" then (fromjson? | .config) else .config end' 2>/dev/null)
            reg_ok=true
        fi
    fi

    if [[ "$reg_ok" == true && -n "$cfg_raw" ]] && echo "$cfg_raw" | jq -e '.config.interface' >/dev/null 2>&1; then
        v4=$(echo "$cfg_raw" | jq -r '.config.interface.addresses.v4 // empty')
        v6=$(echo "$cfg_raw" | jq -r '.config.interface.addresses.v6 // empty')
        local addrs="[]"
        local addr_list=()
        [[ -n "$v4" ]] && addr_list+=("${v4}/32")
        [[ -n "$v6" ]] && addr_list+=("${v6}/128")
        if [[ ${#addr_list[@]} -gt 0 ]]; then
            addrs=$(printf '%s\n' "${addr_list[@]}" | jq -R . | jq -s -c '.')
        fi
        reserved="[]"
        local cid_b64
        cid_b64=$(echo "$cfg_raw" | jq -r '.config.client_id // empty')
        if [[ -n "$cid_b64" ]]; then
            reserved=$(printf '%s' "$cid_b64" | base64 -d 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //' | tr ' ' ',' | awk 'NF{print "["$0"]"}')
            [[ -z "$reserved" ]] && reserved="[]"
        fi
        local peer_pub peer_ep
        peer_pub=$(echo "$cfg_raw" | jq -r '.config.peers[0].public_key // empty')
        peer_ep=$(echo "$cfg_raw" | jq -r '.config.peers[0].endpoint.host // empty')

[[ -n "$WARP_TUN_MTU" ]] || detect_warp_pmtu "$WARP_EP_HOST"
    warp_out=$(jq -nc \
        --arg sk "$wg_priv" \
        --argjson addr "$addrs" \
        --argjson res "$reserved" \
        --arg pk "$peer_pub" \
        --arg ep "$peer_ep" \
        --arg mtu "$WARP_TUN_MTU" \
        --arg ds "$WARP_DOMAIN_STRATEGY" \
        '{tag:"warp", protocol:"wireguard", settings:{mtu:($mtu|tonumber), secretKey:$sk, address:$addr, reserved:$res, domainStrategy:$ds, peers:[{publicKey:$pk, endpoint:$ep}], noKernelTun:true}}')
        has_warp=true
        msg_ok "Cloudflare WARP registered."
    else
        has_warp=false
        warp_out='{}'
        msg_err "WARP registration failed — client egress stays direct."
    fi

    # Merge the WARP outbound + routing into the Xray template.
    local template new_cfg resp
    template=$(api POST /xray/ | jq -r '.obj')
    new_cfg=$(echo "$template" | jq --argjson warp "$warp_out" --argjson has_warp "$has_warp" '
        (.xraySetting | if type=="string" then (fromjson? // {}) else . end)
        | .outbounds = ((.outbounds // []) | map(select(.tag != "warp")))
        | (if $has_warp then .outbounds += [$warp] else . end)
        | (if (.outbounds | map(.tag) | index("direct"))  then . else .outbounds += [{tag:"direct",  protocol:"freedom"}] end)
        | (if (.outbounds | map(.tag) | index("blocked")) then . else .outbounds += [{tag:"blocked", protocol:"blackhole", settings:{}}] end)
        | .routing = {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
              {"type": "field", "outboundTag": "direct", "ip": ["geoip:private"]},
              {"type": "field", "outboundTag": (if $has_warp then "warp" else "direct" end), "network": "tcp,udp"}
            ]
          }
    ')

    resp=$(api POST /xray/update --data-urlencode "xraySetting=${new_cfg}")
    if echo "$resp" | api_ok; then
        if [[ "$has_warp" == true ]]; then
            msg_ok "All client egress routed through Cloudflare WARP."
        else
            msg_inf "Xray routing left on direct egress."
        fi
    else
        msg_err "Failed to save the Xray template: $(echo "$resp" | jq -r '.msg // "unknown error"')"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# COVER SITE (endless-loading decoy by default)
# ─────────────────────────────────────────────────────────────────────────────
install_fake_site() {
    mkdir -p /var/www/html
    local url
    if [[ "$cover" == "random" ]]; then
        local idx site_id
        idx=$(( (RANDOM % FAKE_SITE_COUNT) + 1 ))
        site_id=$(printf "site-%02d" "$idx")
        url="${GITHUB_RAW}/assets/fake-sites/${site_id}/index.html"
    else
        url="${GITHUB_RAW}/assets/decoy/index.html"
    fi

    if curl -fsSL "$url" -o /var/www/html/index.html; then
        chown -R www-data:www-data /var/www/html 2>/dev/null || true
        chmod 644 /var/www/html/index.html
        msg_ok "Cover site installed (${cover})."
    else
        msg_err "Failed to download the cover site from GitHub."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# INSTALL NETWORK DIAGNOSTICS PAGE
# ─────────────────────────────────────────────────────────────────────────────
install_diagnostics() {
    local diag_webroot="/var/www/diagnostics"
    local backend_script="/usr/local/lib/3x-ui-pro/mtr-backend.py"

    mkdir -p "${diag_webroot}"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/index.html" -o "${diag_webroot}/index.html"
    sed -i \
        -e "s|__DIAG_PATH__|${diag_path}|g" \
        -e "s|__SERVER_DOMAIN__|${domain}|g" \
        -e "s|__SERVER_IP__|${IP4}|g" \
        "${diag_webroot}/index.html"

    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest.js" \
        -o "${diag_webroot}/speedtest.js"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest_worker.js" \
        -o "${diag_webroot}/speedtest_worker.js"

    local testfiles="${diag_webroot}/testfiles"
    mkdir -p "${testfiles}"
    [[ -f "${testfiles}/test-15k.bin"  ]] || dd if=/dev/zero bs=1024    count=15   of="${testfiles}/test-15k.bin"  status=none
    [[ -f "${testfiles}/test-17k.bin"  ]] || dd if=/dev/zero bs=1024    count=17   of="${testfiles}/test-17k.bin"  status=none
    [[ -f "${testfiles}/test-100m.bin" ]] || dd if=/dev/zero bs=1048576 count=100  of="${testfiles}/test-100m.bin" status=none
    [[ -f "${testfiles}/test-1g.bin"   ]] || dd if=/dev/zero bs=1048576 count=1024 of="${testfiles}/test-1g.bin"   status=none
    rm -f "${testfiles}/test-512m.bin"
    chown -R www-data:www-data "${diag_webroot}" 2>/dev/null || true

    mkdir -p "$(dirname "${backend_script}")"
    curl -fsSL "${GITHUB_RAW}/assets/diagnostics/mtr-backend.py" -o "${backend_script}"
    chmod 755 "${backend_script}"

    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr)"        2>/dev/null || true
    command -v setcap &>/dev/null && setcap cap_net_raw+ep "$(command -v mtr-packet)" 2>/dev/null || true

    id mtr-backend &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    cat > /etc/systemd/system/mtr-backend.service <<EOF
[Unit]
Description=3x-ui-pro MTR diagnostics backend
After=network.target

[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${backend_script} --port ${mtr_backend_port}
Restart=on-failure
RestartSec=5s
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RemoveIPC=yes
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mtr-backend

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mtr-backend
    systemctl restart mtr-backend

    msg_ok "Network diagnostics installed at https://${domain}/${panel_path}/diag (panel login required)"
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM TUNING (BBR + kernel params)
# ─────────────────────────────────────────────────────────────────────────────
# SSH brute-force protection — same jail the panel host uses.
setup_fail2ban() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y fail2ban >/dev/null 2>&1 \
            || { msg_err "fail2ban install failed — skipping."; return 1; }
    fi
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1d
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    msg_ok "fail2ban is active (sshd: 5 tries / 10m -> ban 1d)."
}

# The opencode CLI for further panel/system tweaking from the terminal.
install_opencode() {
    if command -v opencode >/dev/null 2>&1; then
        msg_ok "opencode is already installed."
        return 0
    fi
    msg_inf "Installing opencode (curl -fsSL https://opencode.ai/v2/install | bash)..."
    curl -fsSL https://opencode.ai/v2/install | bash >/dev/null 2>&1 \
        && msg_ok "opencode installed — run 'opencode' to tweak the panel/system." \
        || msg_err "opencode install failed (network?) — later: curl -fsSL https://opencode.ai/v2/install | bash"
}

tune_system() {
    local params=(
        "net.core.default_qdisc=fq"
        "net.ipv4.tcp_congestion_control=bbr"
        "fs.file-max=2097152"
        "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_sack=1"
        "net.ipv4.tcp_window_scaling=1"
        "net.core.rmem_max=16777216"
        "net.core.wmem_max=16777216"
        "net.ipv4.tcp_rmem=4096 87380 16777216"
        "net.ipv4.tcp_wmem=4096 65536 16777216"
    )
    for p in "${params[@]}"; do
        grep -qxF "$p" /etc/sysctl.conf || echo "$p" >> /etc/sysctl.conf
    done
    sysctl -p >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# CRON JOBS
# ─────────────────────────────────────────────────────────────────────────────
setup_cron() {
    crontab -l 2>/dev/null | grep -v "certbot\|x-ui\|cloudflareips" | crontab -
    (crontab -l 2>/dev/null; echo '@daily   x-ui restart > /dev/null 2>&1 && nginx -s reload')    | crontab -
    # Certs were issued with --standalone: renewal needs port 80 free,
    # so stop nginx for the few seconds certbot runs
    (crontab -l 2>/dev/null; echo '@monthly certbot renew --non-interactive --pre-hook "systemctl stop nginx" --post-hook "systemctl start nginx" > /dev/null 2>&1') | crontab -
}

# ─────────────────────────────────────────────────────────────────────────────
# FIREWALL
# ─────────────────────────────────────────────────────────────────────────────
setup_firewall() {
    ufw disable
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    # Extra protocols that cannot share :443 (UDP/QUIC or plaintext transports)
    ufw allow "${kcp_port}"/udp
    ufw allow "${tuic_port}"/udp
    ufw allow "${wg_port}"/udp
    ufw allow "${awg_port}"/udp
    ufw allow "${ss_port}"/tcp
    ufw allow "${ss_port}"/udp
    ufw --force enable
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW RESULTS
# ─────────────────────────────────────────────────────────────────────────────
show_results() {
    clear

    local panel_up=false
    systemctl is-active --quiet x-ui && panel_up=true

    if [[ "$panel_up" == true ]]; then
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "X-UI Secure Panel: https://${domain}/${panel_path}/"
        echo -e "Username:  ${config_username}"
        echo -e "Password:  ${config_password}"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Eternal users: ${eternal_users} × (no expiry, unlimited traffic each)"
        [[ -n "$label" ]] && msg_inf "Label: ${label}"
        msg_inf "Full list (panel + every subscription link): /root/README_PANEL.md"
        local u
        for ((u = 1; u <= eternal_users; u++)); do
            echo -e "  #${u}  https://${domain}/${json_path}/${subid_base}-${u}"
        done
        echo -e "  raw / Clash: same subId under /${sub_path}/ and /${clash_path}/"
        echo -e "  WireGuard: .../${sub_path}/${subid_base}-N-wg    AmneziaWG: .../${sub_path}/${subid_base}-N-awg"
        msg_inf "  (use a JSON link in Happ — RoscomVPN routing rides along)"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Happ (JSON) subscription #1 — scan the QR to import:"
        local qr_url="https://${domain}/${json_path}/${subid_base}-1"
        echo -e "  ${qr_url}"
        if ! command -v qrencode >/dev/null 2>&1; then
            msg_inf "qrencode is missing — installing it (apt-get install -y qrencode)..."
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y qrencode >/dev/null 2>&1 \
                || msg_err "qrencode install failed — QR skipped, use the link above (apt-get install -y qrencode)"
        fi
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 -s 2 -m 1 "$qr_url" 2>/dev/null \
                || qrencode -t UTF8 "$qr_url" 2>/dev/null \
                || msg_err "QR rendering failed — use the link above"
        fi
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "SNI masking: ${sni_domain}  |  cover site: ${cover}"
        local tcp_list="reality, ws, grpc, httpupgrade, xhttp, trojan, vmess"
        [[ -n "$MTPROTO_ID" ]] && tcp_list="${tcp_list}, mtproto"
        echo -e "443/tcp : ${tcp_list}"
        echo -e "443/udp : hysteria2"
        echo -e "kcp/udp : ${kcp_port}   tuic/udp: ${tuic_port}   wireguard/udp: ${wg_port}"
        echo -e "awg/udp : ${awg_port}   shadowsocks tcp+udp: ${ss_port}"
        msg_inf "mKCP links require a client with VLESS Encryption (Xray 25.x+/Happ)"
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Network Diagnostics (panel login required): https://${domain}/${panel_path}/diag"
        if [[ "$WARP_ENABLED" == "true" ]]; then
            msg_inf "Egress: Cloudflare WARP"
        else
            msg_err "Egress: direct (WARP was not registered — enable it in the panel: Xray > WARP)"
        fi
        sleep 4
        if ! pgrep -f "xray-linux" >/dev/null 2>&1 && ! pgrep -x xray >/dev/null 2>&1; then
            msg_err "Xray core is NOT running — check: journalctl -u x-ui -n 100 --no-pager"
        fi
        msg_inf "────────────────────────────────────────────────────────────────────────────────"
        msg_inf "Please save this screen!"
    else
        nginx -t
        printf '0\n' | x-ui | grep --color=never -i ':'
        msg_err "x-ui or nginx check failed. Try on a clean Linux install."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE / LOAD STATE
# ─────────────────────────────────────────────────────────────────────────────
generate_state() {
    panel_port=$(make_port)
    sub_port=$(make_port)
    mtr_backend_port=$(make_port)

    reality_port=$(make_port)
    ws_port=$(make_port)
    grpc_port=$(make_port)
    httpupgrade_port=$(make_port)
    xhttp_port=$(make_port)
    trojan_ws_port=$(make_port)
    trojan_grpc_port=$(make_port)
    vmess_ws_port=$(make_port)
    vmess_grpc_port=$(make_port)
    mtproto_port=$(make_port)

    kcp_port=$(make_udp_port)
    tuic_port=$(make_udp_port)
    wg_port=$(make_udp_port)
    awg_port=$(make_udp_port)
    ss_port=$(make_port)

    sub_path=$(gen_random_string 10)
    json_path=$(gen_random_string 10)
    clash_path=$(gen_random_string 10)
    panel_path=$(gen_random_string 10)
    ws_path=$(gen_random_string 10)
    grpc_path=$(gen_random_string 10)
    httpupgrade_path=$(gen_random_string 10)
    xhttp_path=$(gen_random_string 10)
    trojan_ws_path=$(gen_random_string 10)
    trojan_grpc_path=$(gen_random_string 10)
    vmess_ws_path=$(gen_random_string 10)
    vmess_grpc_path=$(gen_random_string 10)
    diag_path="/net-$(gen_random_string 12)/"
    diag_token=$(gen_random_string 16)

    config_username=$(gen_random_string 10)
    config_password=$(gen_random_string 10)
    client_base="eternal"
    subid_base=$(gen_random_string 14)

    reality_fp=$(shuf -e chrome firefox safari edge 2>/dev/null | head -1)
    [[ -n "$reality_fp" ]] || reality_fp="firefox"
    reality_key=""
    reality_pub=""
    gen_reality_keys

    wg_key=$(gen_wg_key)
    ss_password=$(openssl rand -base64 32)
}

patch_state() {
    # Reuse everything from the previous install; only fill in what's missing.
    load_state
    domain="${DOMAIN:-$domain}"
    sni="${SNI:-$sni}"
    cover="${COVER:-$cover}"
    # No state file (e.g. an installation made by an older release) — recover
    # what the panel itself recorded, and let the rest be regenerated.
    if [[ -z "${PANEL_PORT:-}" ]]; then
        local dbval
        dbval=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null)
        [[ -n "$dbval" ]] && PANEL_PORT="$dbval"
        dbval=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webBasePath' LIMIT 1;" 2>/dev/null)
        [[ -n "$dbval" ]] && PANEL_PATH="${dbval#/}"
        dbval=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null)
        [[ -n "$dbval" ]] && SUB_PORT="$dbval"
        dbval=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;" 2>/dev/null)
        [[ -n "$dbval" ]] && SUB_PATH="${dbval//\//}"
        dbval=$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='subJsonPath' LIMIT 1;" 2>/dev/null)
        [[ -n "$dbval" ]] && JSON_PATH="${dbval//\//}"
    fi
    panel_port="${PANEL_PORT:-$(make_port)}"
    sub_port="${SUB_PORT:-$(make_port)}"
    mtr_backend_port="${MTR_PORT:-$(make_port)}"
    reality_port="${REALITY_PORT:-$(make_port)}"
    ws_port="${WS_PORT:-$(make_port)}"
    grpc_port="${GRPC_PORT:-$(make_port)}"
    httpupgrade_port="${HTTPUPGRADE_PORT:-$(make_port)}"
    xhttp_port="${XHTTP_PORT:-$(make_port)}"
    trojan_ws_port="${TROJAN_WS_PORT:-$(make_port)}"
    trojan_grpc_port="${TROJAN_GRPC_PORT:-$(make_port)}"
    vmess_ws_port="${VMESS_WS_PORT:-$(make_port)}"
    vmess_grpc_port="${VMESS_GRPC_PORT:-$(make_port)}"
    mtproto_port="${MTPROTO_PORT:-$(make_port)}"
    kcp_port="${KCP_PORT:-$(make_udp_port)}"
    tuic_port="${TUIC_PORT:-$(make_udp_port)}"
    wg_port="${WG_PORT:-$(make_udp_port)}"
    awg_port="${AWG_PORT:-$(make_udp_port)}"
    ss_port="${SS_PORT:-$(make_port)}"
    sub_path="${SUB_PATH:-$(gen_random_string 10)}"
    json_path="${JSON_PATH:-$(gen_random_string 10)}"
    clash_path="${CLASH_PATH:-$(gen_random_string 10)}"
    panel_path="${PANEL_PATH:-$(gen_random_string 10)}"
    ws_path="${WS_PATH:-$(gen_random_string 10)}"
    grpc_path="${GRPC_PATH:-$(gen_random_string 10)}"
    httpupgrade_path="${HTTPUPGRADE_PATH:-$(gen_random_string 10)}"
    xhttp_path="${XHTTP_PATH:-$(gen_random_string 10)}"
    trojan_ws_path="${TROJAN_WS_PATH:-$(gen_random_string 10)}"
    trojan_grpc_path="${TROJAN_GRPC_PATH:-$(gen_random_string 10)}"
    vmess_ws_path="${VMESS_WS_PATH:-$(gen_random_string 10)}"
    vmess_grpc_path="${VMESS_GRPC_PATH:-$(gen_random_string 10)}"
    diag_path="${DIAG_PATH:-/net-$(gen_random_string 12)/}"
    diag_token="${DIAG_TOKEN:-$(gen_random_string 16)}"
    reality_key="${REALITY_KEY:-}"
    reality_pub="${REALITY_PUB:-}"
    reality_fp="${REALITY_FP:-firefox}"
    config_username=$(sqlite3 "$XUIDB" "SELECT username FROM users LIMIT 1;" 2>/dev/null)
    [[ -n "$config_username" ]] || config_username=$(gen_random_string 10)
    # The panel stores only a hash, so the old password can't be recovered —
    # mint a fresh one on every patch.
    config_password=$(gen_random_string 10)
    client_base="${CLIENT_BASE:-${CLIENT_EMAIL:-eternal}}"
    subid_base="${SUBID_BASE:-${CLIENT_SUBID:-$(gen_random_string 14)}}"
    eternal_users="${users_arg:-${ETERNAL_USERS:-10}}"
    wg_key="${WG_KEY:-$(gen_wg_key)}"
    ss_password="${SS_PASSWORD:-$(openssl rand -base64 32)}"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
WARP_ENABLED="false"

main() {
    # In patch mode reuse the domain/SNI/cover recorded by the previous install
    # unless the caller overrides them.
    if [[ ${PATCH} == *"y"* ]]; then
        load_state
        domain="${domain:-$DOMAIN}"
        if [[ "$sni" == "bing" ]]; then sni="${SNI_DOMAIN:-${SNI:-bing}}"; fi
        eternal_users="${users_arg:-${ETERNAL_USERS:-10}}"
        cover="${COVER:-$cover}"
        label="${label:-$LABEL}"
    fi

    validate_domains
    validate_mask_sni

    # mtg talks to Telegram directly: skip the inbound when this host cannot
    # reach Telegram (checked before nginx is generated, so 443 stays clean).
    MT_ON=yes
    telegram_reachable || MT_ON=no
    if [[ "$MT_ON" == no ]]; then
        msg_inf "MTProto skipped: Telegram servers are unreachable from this host."
    fi

    if [[ ${PATCH} == *"y"* ]]; then
        if [[ ! -f "$XUIDB" ]]; then
            msg_err "No existing panel found — run the installer without -patch."
            exit 1
        fi
        patch_state
        get_server_ip >/dev/null 2>&1 || true
        INSTALL=n install_packages >/dev/null 2>&1 || true
        get_ssl_certs
        init_api
        ensure_xray_core
        delete_managed_inbounds
        delete_managed_hosts
    else
        clean_previous_install
        install_packages
        get_server_ip
        get_ssl_certs
        install_panel
        eternal_users="${users_arg:-10}"
        generate_state
        save_state
    fi

    configure_panel_settings
    configure_nginx

    init_api
    ensure_xray_core

    detect_warp_pmtu "$WARP_EP_HOST"
    install_inbounds
    install_eternal_users
    install_hosts
    configure_warp

    WARP_ENABLED=$(api POST /xray/warp/data | jq -r 'if (.obj // "" | length) > 0 then "true" else "false" end' 2>/dev/null)
    [[ "$WARP_ENABLED" == "true" ]] || WARP_ENABLED="false"

    install_fake_site
    install_diagnostics
tune_system
    setup_fail2ban
    [[ "$OPENCODE" == *"y"* ]] && install_opencode
    setup_cron
    setup_firewall

    if ! systemctl is-enabled --quiet x-ui; then
        systemctl daemon-reload && systemctl enable x-ui.service
    fi
    x-ui restart

    save_state
    save_panel_readme
    show_results
}

main
