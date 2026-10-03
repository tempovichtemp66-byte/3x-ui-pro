#!/bin/bash
#################### 3x-ui-pro — multi-node (x-ui-node.sh) #####################
#
# One subscription, many servers. Run ON THE MASTER (a 3x-ui-pro panel):
#
#   bash x-ui-node.sh -node "USA|https|us.example.com|443|/AbCdEf/|TOKEN"
#
# What it does (verified against 3x-ui v3.8.5):
#   1. Registers the slave panel as a node on the master (monitoring/health).
#   2. For every matching inbound of the master (vless/trojan/vmess over
#      ws/httpupgrade/xhttp) creates a *host override* pointing at the
#      slave's :443 entry with the slave's path — the master's subscription
#      then emits an extra profile per slave for the same client credentials.
#   3. Provisions the master's eternal clients (same UUIDs) onto the slave,
#      so the slave's xray accepts those connections.
#
# Protocols covered: vless/trojan/vmess over ws, httpupgrade, xhttp.
# Skipped (cannot be bridged this way): REALITY (server keys), gRPC
# (serviceName is not overridable), kcp/tuic/hysteria/shadowsocks (own
# auth/keys), wireguard/amneziawg (per-server peers), mtproto (separate mtg).
#
# Node spec (repeatable):
#   name|scheme|address|port|basePath|apiToken
#     scheme   https (default) or http
#     address  hostname or IP only (no scheme, no port)
#     port     the node panel's web port (usually 443 via nginx)
#     basePath the node panel's web base path, MUST end with '/'
#     apiToken the node's API token — run ONCE on the node:
#              /usr/local/x-ui/x-ui setting -getApiToken true
#
# !!! WARNING: that command ROTATES the token on every call. Fetch it once,
#     paste it here, and do NOT re-run it afterwards or the master will get
#     401/404 from the node (fix: re-add the node with a fresh token).
#
# Modes:
#   bash x-ui-node.sh -slave [-name "Label"]     # ON the slave: prints a ready command
#                                                #   (default label = server country:
#                                                #   curl ifconfig.co/country)
#   bash x-ui-node.sh -list                      # nodes on this master
#   bash x-ui-node.sh -check                     # health + coverage check
#   bash x-ui-node.sh -del <name> [...]          # remove node + its hosts/clients
#   bash x-ui-node.sh -users N                   # provision only first N users
#   bash x-ui-node.sh -tls skip|verify|pin       # TLS verify mode (default verify)
#
# WARNING: educational purposes only. Use only on servers you own and comply
# with the laws of your country. Provided "as is", without warranty — see
# DISCLAIMER.md in the repository.
#
[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash $0"; exit 1; }

msg_ok()  { echo -e "\e[1;42m $1 \e[0m"; }
msg_err() { echo -e "\e[1;41m $1 \e[0m"; }
msg_inf() { echo -e "\e[1;34m$1\e[0m"; }

STATE_FILE="/etc/x-ui/3x-ui-pro/install.env"

NODES=()
USERS_ARG=""
TLS_MODE="verify"
PIN_SHA=""
MODE="add"
DEL_NAMES=()
SLAVE_NAME=""   # -name: node label used by -slave output

while [[ $# -gt 0 ]]; do
    case "$1" in
        -node)  NODES+=("$2"); shift 2 ;;
        -users) USERS_ARG="$2"; shift 2 ;;
        -tls)   TLS_MODE="$2"; shift 2 ;;
        -pin_sha) PIN_SHA="$2"; shift 2 ;;
        -slave) MODE="slave"; shift ;;
        -name)  SLAVE_NAME="$2"; shift 2 ;;
        -list)  MODE="list"; shift ;;
        -check) MODE="check"; shift ;;
        -del)   MODE="del"; DEL_NAMES+=("$2"); shift 2 ;;
        *)      NODES+=("$1"); shift ;;   # bare spec accepted: x-ui-node.sh "NAME|...|TOKEN"
    esac
done

# If no -node args were given and stdin is piped, read specs from stdin.
if [[ ${#NODES[@]} -eq 0 ]] && [[ ! -t 0 ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && NODES+=("$line")
    done
fi

# ─── Master panel API (token is minted ONCE per run — it rotates per call) ──
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
PANEL_PORT="${PANEL_PORT:-2053}"
PANEL_PATH="${PANEL_PATH:-}"
PANEL_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
API_TOKEN=""
for i in 1 2 3 4 5; do
    API_TOKEN=$(/usr/local/x-ui/x-ui setting -getApiToken true 2>&1 | sed -n 's/^apiToken: *//p' | tail -n1)
    [[ -n "$API_TOKEN" ]] && break
    sleep 2
done
[[ -n "$API_TOKEN" ]] || { msg_err "Failed to mint the master panel API token."; exit 1; }

api() { # api <METHOD> <path> [extra curl args...]
    local method="$1" path="$2"
    shift 2
    curl -sk --max-time 90 -X "$method" \
        -H "Authorization: Bearer ${API_TOKEN}" \
        "${PANEL_BASE}/panel/api${path}" "$@"
}

api_ok() { jq -e '.success == true' >/dev/null 2>&1; }

# ─── Node spec parsing ───────────────────────────────────────────────────────
parse_spec() { # <spec> -> N_NAME N_SCHEME N_ADDR N_PORT N_BASE N_TOKEN
    local spec="$1"
    N_NAME=$(echo "$spec" | cut -d'|' -f1)
    N_NAME=$(echo "$N_NAME" | tr -d '|' | tr '[:space:]' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
    N_NAME="${N_NAME:0:32}"
    N_SCHEME=$(echo "$spec" | cut -d'|' -f2); [[ -n "$N_SCHEME" ]] || N_SCHEME="https"
    N_ADDR=$(echo "$spec" | cut -d'|' -f3)
    N_PORT=$(echo "$spec" | cut -d'|' -f4)
    N_BASE=$(echo "$spec" | cut -d'|' -f5)
    N_TOKEN=$(echo "$spec" | cut -d'|' -f6)
    [[ -n "$N_NAME" && -n "$N_ADDR" && -n "$N_PORT" && -n "$N_BASE" && -n "$N_TOKEN" ]] \
        || { msg_err "Bad -node spec '$spec' (need: name|scheme|address|port|basePath|apiToken)"; return 1; }
    [[ "$N_SCHEME" == "http" || "$N_SCHEME" == "https" ]] || { msg_err "Bad scheme '$N_SCHEME'"; return 1; }
    [[ "$N_BASE" == */ ]] || N_BASE="${N_BASE}/"
    [[ "$N_ADDR" != *:* ]] || { msg_err "Address '$N_ADDR' must not contain a port (use the port field)."; return 1; }
    case "$TLS_MODE" in verify|skip|pin) ;; *) msg_err "Bad -tls '$TLS_MODE'"; return 1 ;; esac
    return 0
}

# Slave panel API helper (token comes from the spec; it does NOT rotate)
slave_api() { # slave_api <base-url> <token> <METHOD> <path> [extra curl args...]
    local base="$1" tok="$2" method="$3" path="$4"
    base="${base%/}"
    shift 4
    curl -sk --max-time 60 -X "$method" \
        -H "Authorization: Bearer ${tok}" \
        "${base}/panel/api${path}" "$@"
}

# ─── Eternal users + their UUIDs on the master ──────────────────────────────
eternal_users_list() {
    local base="${CLIENT_BASE:-eternal}" count
    if [[ -n "$USERS_ARG" ]] && [[ "$USERS_ARG" =~ ^[0-9]+$ ]]; then
        count="$USERS_ARG"
    else
        count="${ETERNAL_USERS:-10}"
    fi
    local i
    for ((i = 1; i <= count; i++)); do echo "${base}-${i}"; done
}

master_client_uuid() { # <email> -> uuid
    sqlite3 /etc/x-ui/x-ui.db "select uuid from clients where email='$1';" 2>/dev/null | head -n1
}

# Supported transport list for bridging: uuid-based + path-overridable.
# <protocol>:<network> pairs are matched between master and slave.
supported_pair() { # <protocol> <network> -> 0 if supported
    local proto="$1" net="$2"
    case "${proto}:${net}" in
        vless:ws|vless:httpupgrade|vless:xhttp|trojan:ws|trojan:httpupgrade|trojan:xhttp|vmess:ws|vmess:httpupgrade|vmess:xhttp) return 0 ;;
        *) return 1 ;;
    esac
}

# Path for a given streamSettings JSON
path_for() { # <streamSettings-json> <network> -> path
    local ss="$1" net="$2"
    case "$net" in
        ws)          echo "$ss" | jq -r '.wsSettings.path // empty' ;;
        httpupgrade) echo "$ss" | jq -r '.httpupgradeSettings.path // empty' ;;
        xhttp)       echo "$ss" | jq -r '.xhttpSettings.path // empty' ;;
    esac
}

host_for() { # <streamSettings-json> -> host
    echo "$1" | jq -r '.wsSettings.host // .httpupgradeSettings.host // .xhttpSettings.host // empty'
}

# ─── Modes ───────────────────────────────────────────────────────────────────
# -check / -del need the slave token; the panel masks apiToken in nodes/list,
# so it must come from a -node spec (same name as the registered node).
declare -A NODE_BASES=() NODE_TOKENS=()
for spec in "${NODES[@]}"; do
    parse_spec "$spec" || continue
    NODE_BASES["$N_NAME"]="${N_SCHEME}://${N_ADDR}:${N_PORT}${N_BASE}"
    NODE_TOKENS["$N_NAME"]="$N_TOKEN"
done

mode_list() {
    local out
    out=$(api GET /nodes/list) || { msg_err "nodes/list failed"; exit 1; }
    if [[ "$(echo "$out" | jq -r '[.obj[]?] | length')" == "0" ]]; then
        msg_inf "No nodes on this master yet."
        return 0
    fi
    echo "$out" | jq -r '.obj[]? | "\(.id)\t\(.name)\t\(.status)\taddr=\(.address):\(.port)\(.basePath)\tinbounds=\(.inboundCount)\tclients=\(.clientCount)"'
}

mode_del() {
    local name out id
    for name in "${DEL_NAMES[@]}"; do
        out=$(api GET /nodes/list)
        id=$(echo "$out" | jq -r --arg n "$name" '.obj[]? | select(.name == $n) | .id' | head -n1)
        [[ -n "$id" ]] || { msg_err "Node '$name' not found on the master."; continue; }

        # CRITICAL ORDER: disable the node FIRST so the master's reconcile job
        # stops pushing state to it. Otherwise deleting the imported inbounds
        # makes the master "reconcile" by deleting the SAME inbounds on the
        # slave panel (observed: wiped all 16 inbounds on a live slave).
        local payload
        payload=$(echo "$out" | jq -c --argjson nid "$id" '.obj[]? | select(.id == $nid) | {name, scheme, address, port, basePath, apiToken, enable:false, allowPrivateAddress, tlsVerifyMode, pinnedCertSha256}')
        [[ -n "$payload" ]] && api POST "/nodes/update/${id}" -H 'Content-Type: application/json' -d "$payload" >/dev/null
        msg_inf "  node '$name' disabled (reconcile stopped)."

        # Remove host overrides created for this node (incl. old-style bare groups).
        local hids
        hids=$(api GET /hosts/list | jq -r --arg r "3x-ui-pro node ${name} " --arg rb "3x-ui-pro node ${name}" '.obj[]? | select((.remark | startswith($r)) or .remark == $rb) | .groupId' | sort -u)
        for hid in $hids; do
            api POST "/hosts/del/${hid}" >/dev/null && msg_inf "  host group ${hid} removed"
        done

        # Remove the slave-side clients provisioned by this script.
        local s_base s_tok
        s_base="${NODE_BASES[$name]:-}"
        s_tok="${NODE_TOKENS[$name]:-}"
        if [[ -n "$s_tok" ]]; then
            local cids cid
            cids=$(slave_api "$s_base" "$s_tok" GET /clients/list | jq -r --arg p "${name}-" '.obj[]? | select(.email | startswith($p)) | .id')
            for cid in $cids; do
                slave_api "$s_base" "$s_tok" POST "/clients/del/${cid}" >/dev/null && msg_inf "  slave client ${cid} removed"
            done
        else
            msg_inf "  no -node spec with a token for '$name' — slave-side clients were NOT removed (re-run with -node \"$name|...|TOKEN\")"
        fi

        # Node inbounds must be deleted before the node itself.
        local ib_ids id2
        ib_ids=$(api GET /inbounds/list | jq -r --argjson nid "$id" '[.obj[]? | select(.nodeId == $nid) | .id] | join(" ")')
        for id2 in $ib_ids; do
            api POST "/inbounds/del/${id2}" >/dev/null || true
        done
        [[ -n "$ib_ids" ]] && msg_inf "Removed ${ib_ids// /,} imported inbound(s) of node '$name'."

        if api POST "/nodes/del/${id}" | api_ok; then
            msg_ok "Node '$name' deleted."
        else
            msg_err "Failed to delete node '$name'."
        fi
    done
}

mode_check() {
    local out
    out=$(api GET /nodes/list)
    if [[ "$(echo "$out" | jq -r '[.obj[]?] | length')" == "0" ]]; then
        msg_inf "No nodes on this master yet."
        return 0
    fi
    echo "$out" | jq -r '.obj[]? | "\(.name): \(.status) (\(.inboundCount) inbounds, \(.clientCount) clients) latency=\(.latencyMs)ms"'
    local name hcount
    for name in $(echo "$out" | jq -r '.obj[]? | .name'); do
        hcount=$(api GET /hosts/list | jq -r --arg r "3x-ui-pro node ${name} " '[.obj[]? | select(.remark | startswith($r))] | length')
        echo "  host overrides on master for '${name}': ${hcount}"
    done
local email uuid ok=1
    for email in $(eternal_users_list); do
        uuid=$(master_client_uuid "$email")
        if [[ -z "$uuid" ]]; then
            msg_err "  master client '$email' not found (uuid lookup failed)"
            ok=0; continue
        fi
        for name in $(echo "$out" | jq -r '.obj[]? | .name'); do
            local n_tok s_base
            n_tok="${NODE_TOKENS[$name]:-}"
            if [[ -z "$n_tok" ]]; then
                msg_inf "  (coverage on '${name}' requires a -node spec with its token)"
                continue
            fi
            s_base="${NODE_BASES[$name]:-}"
            if slave_api "$s_base" "$n_tok" GET /inbounds/list | jq -e --arg u "$uuid" '[.obj[]? | select((.settings | tostring) | contains($u))] | length > 0' >/dev/null 2>&1; then
                msg_ok "  uuid of '${email}' is provisioned on '${name}'"
            else
                msg_err "  uuid of '${email}' is NOT on '${name}'"
                ok=0
            fi
        done
    done
    [[ "$ok" == "1" ]] && msg_ok "Coverage check passed."
}

# ─── Add nodes + hosts + provisioning ───────────────────────────────────────
mode_add() {
    local spec node_id
    local -A NODE_IDS=()
    local -A NODE_BASES=()   # name -> slave api base url
    local -A NODE_TOKENS=()  # name -> slave token

    [[ ${#NODES[@]} -gt 0 ]] || { msg_err "No -node specs given (see header)."; exit 1; }

    # 1. Register nodes on the master (reuse existing ones).
    for spec in "${NODES[@]}"; do
        parse_spec "$spec" || exit 1
        NODE_BASES["$N_NAME"]="${N_SCHEME}://${N_ADDR}:${N_PORT}${N_BASE}"
        NODE_TOKENS["$N_NAME"]="$N_TOKEN"
        local existing payload resp
        existing=$(api GET /nodes/list | jq -r --arg n "$N_NAME" '.obj[]? | select(.name == $n) | .id' | head -n1)
        if [[ -n "$existing" ]]; then
            msg_inf "→ Node '$N_NAME' already exists (id=$existing) — refreshing its token."
            payload=$(jq -nc --arg name "$N_NAME" --arg scheme "$N_SCHEME" --arg addr "$N_ADDR" \
                --argjson port "$N_PORT" --arg base "$N_BASE" --arg tok "$N_TOKEN" \
                --arg tls "$TLS_MODE" --arg pin "$PIN_SHA" \
                '{name:$name, remark:"3x-ui-pro node", scheme:$scheme, address:$addr, port:($port|tonumber),
                  basePath:$base, apiToken:$tok, enable:true, allowPrivateAddress:true,
                  tlsVerifyMode:$tls, pinnedCertSha256:$pin}')
            api POST "/nodes/update/${existing}" -H 'Content-Type: application/json' -d "$payload" | api_ok \
                || msg_err "  failed to refresh token of '$N_NAME'"
            NODE_IDS["$N_NAME"]="$existing"
        else
            msg_inf "→ Adding node '$N_NAME' (${N_SCHEME}://${N_ADDR}:${N_PORT}${N_BASE})..."
            payload=$(jq -nc --arg name "$N_NAME" --arg scheme "$N_SCHEME" --arg addr "$N_ADDR" \
                --argjson port "$N_PORT" --arg base "$N_BASE" --arg tok "$N_TOKEN" \
                --arg tls "$TLS_MODE" --arg pin "$PIN_SHA" \
                '{name:$name, remark:"3x-ui-pro node", scheme:$scheme, address:$addr, port:($port|tonumber),
                  basePath:$base, apiToken:$tok, enable:true, allowPrivateAddress:true,
                  tlsVerifyMode:$tls, pinnedCertSha256:$pin}')
            resp=$(api POST /nodes/test -H 'Content-Type: application/json' -d "$payload")
            if ! echo "$resp" | api_ok; then
                msg_err "Node '$N_NAME' unreachable: $(echo "$resp" | jq -r '.msg // "unknown error"')"
                continue
            fi
            resp=$(api POST /nodes/add -H 'Content-Type: application/json' -d "$payload")
            if echo "$resp" | api_ok; then
                node_id=$(echo "$resp" | jq -r '.obj.id // empty')
                NODE_IDS["$N_NAME"]="$node_id"
                msg_ok "Node '$N_NAME' added (id=$node_id)."
            else
                msg_err "Failed to add node '$N_NAME': $(echo "$resp" | jq -r '.msg // "unknown error"')"
            fi
        fi
    done

    [[ ${#NODE_IDS[@]} -gt 0 ]] || { msg_err "No nodes were registered."; exit 1; }

    # 2. Master local inbounds (nodeId empty) of supported transports.
    local master_ibs
    master_ibs=$(api GET /inbounds/list | jq -c '[.obj[]? | select((.nodeId // null) == null)]')

    local name
    for name in "${!NODE_IDS[@]}"; do
        local s_base s_tok
        s_base="${NODE_BASES[$name]}"
        s_tok="${NODE_TOKENS[$name]}"

        # 2a. Slave inbounds of supported transports (id + path + host).
        local slave_ibs
        slave_ibs=$(slave_api "$s_base" "$s_tok" GET /inbounds/list | jq -c '.obj // []')

        # 2b. Host overrides on the master for every supported master inbound.
        local n_host ok=1
        n_host=$(echo "$s_base" | sed -E 's|^https?://([^:/]+).*|\1|')
        local ib
        while IFS= read -r ib; do
            [[ -z "$ib" ]] && continue
            local proto net path host remark ids
            proto=$(echo "$ib" | jq -r '.protocol')
            net=$(echo "$ib" | jq -r '.streamSettings.network // "tcp"')
            supported_pair "$proto" "$net" || continue
            path=$(path_for "$(echo "$ib" | jq -c '.streamSettings')" "$net")
            host=$(host_for "$(echo "$ib" | jq -c '.streamSettings')")
            ids=$(echo "$ib" | jq -r '.id')
            # find the slave counterpart (same protocol+network) and take its path/host
            local sib sp sh
            sib=$(echo "$slave_ibs" | jq -c --arg p "$proto" --arg n "$net" '[.[]? | select(.protocol==$p and (.streamSettings.network // "tcp")==$n)] | .[0] // empty')
            if [[ -n "$sib" ]]; then
                sp=$(path_for "$(echo "$sib" | jq -c '.streamSettings')" "$net")
                sh=$(host_for "$(echo "$sib" | jq -c '.streamSettings')")
                [[ -n "$sp" ]] && path="$sp"
                [[ -n "$sh" ]] && host="$sh"
            fi
            remark="3x-ui-pro node ${name} ${proto}-${net}"
            local payload resp2 gid
            gid=$(api GET /hosts/list | jq -r --arg r "$remark" '.obj[]? | select(.remark == $r) | .groupId' | head -n1)
            payload=$(jq -nc --arg r "$remark" --arg h "$n_host" --argjson iid "$ids" \
                --arg p "${path:-}" --arg hh "${host:-}" \
                '{remark:$r, inboundIds:[$iid], hosts:[$h], port:443, security:"tls",
                  sni:"", hostHeader:$hh, path:$p, sortOrder:1, fingerprint:"firefox",
                  allowInsecure:false, pinnedPeerCertSha256:[], alpn:[]}')
            if [[ -n "$gid" ]]; then
                resp2=$(api POST "/hosts/update/${gid}" -H 'Content-Type: application/json' -d "$payload")
            else
                resp2=$(api POST /hosts/add -H 'Content-Type: application/json' -d "$payload")
            fi
            echo "$resp2" | api_ok || { msg_err "  host override failed for master inbound ${ids} (${proto}/${net})"; ok=0; }
        done <<< "$(echo "$master_ibs" | jq -c '.[]')"
        [[ "$ok" == "1" ]] && msg_ok "Host overrides for '${name}' are in place (${n_host}:443)."

        # 2c. Provision master clients onto the slave (same UUIDs, unique emails).
        local email uuid ok2=1
        for email in $(eternal_users_list); do
            uuid=$(master_client_uuid "$email")
            [[ -n "$uuid" ]] || { msg_err "  uuid for '${email}' not found"; ok2=0; continue; }
            local s_email
            s_email="${name}-${email}"
            # attach to the slave's supported inbounds (ws/httpupgrade/xhttp)
            local groups
            groups=$(echo "$slave_ibs" | jq -c '[.[]? | select((.streamSettings.network // "tcp")=="ws" or (.streamSettings.network // "tcp")=="httpupgrade" or (.streamSettings.network // "tcp")=="xhttp") | .id]')
            if [[ "$groups" == "[]" ]]; then
                msg_err "  slave has no supported inbounds for '${email}'"
                ok2=0; continue
            fi
            # Idempotency with coverage: an existing slave client is reused only
            # if the uuid is already on every supported inbound, otherwise it is
            # recreated with the full set (avoids stale partial provisioning).
            local want covered
            want=$(echo "$groups" | jq 'length')
            covered=$(echo "$slave_ibs" | jq -c --arg u "$uuid" '[.[]? | select((.streamSettings.network // "tcp")=="ws" or (.streamSettings.network // "tcp")=="httpupgrade" or (.streamSettings.network // "tcp")=="xhttp") | select((.settings | tostring) | contains($u))] | length')
            if [[ "$covered" == "$want" ]]; then
                continue
            fi
            local cid
            cid=$(slave_api "$s_base" "$s_tok" GET /clients/list | jq -r --arg e "$s_email" '.obj[]? | select(.email == $e) | .id' | head -n1)
            [[ -n "$cid" ]] && slave_api "$s_base" "$s_tok" POST "/clients/del/${cid}" >/dev/null 2>&1 || true
            local payload3
            payload3=$(jq -nc --arg u "$uuid" --arg e "$s_email" --argjson ids "$groups" \
                '{client:{id:$u, email:$e, subId:$e, totalGB:0, expiryTime:0, enable:true,
                  limitIp:0, flow:"", comment:"3x-ui-pro multi-node"}, inboundIds:$ids}')
            slave_api "$s_base" "$s_tok" POST /clients/add -H 'Content-Type: application/json' -d "$payload3" | api_ok \
                || { msg_err "  failed to provision '${email}' on '${name}'"; ok2=0; }
        done
        [[ "$ok2" == "1" ]] && msg_ok "Master clients provisioned on '${name}' (same UUIDs)."
    done

    msg_inf "Subscription (unchanged URL): https://${DOMAIN}/${SUB_PATH}/${SUBID_BASE}-1"
    msg_inf "Each supported inbound now also emits a profile pointing at every node (:443)."
}

# ─── Slave helper: print a ready-made command for the master ────────────────
mode_slave() {
    # Run ON THE SLAVE. Prints one line the master owner can paste as-is.
    local domain="" port="" path="" label=""
    [[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
    domain="$DOMAIN"; port="$PANEL_PORT"; path="$PANEL_PATH"; label="$LABEL"
    if [[ -z "$domain" || -z "$port" || -z "$path" ]]; then
        local out
        out=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null)
        port=$(echo "$out" | sed -n 's/^port: *//p' | head -n1)
        path=$(echo "$out" | sed -n 's/^webBasePath: *//p' | head -n1)
        domain=$(hostname -f 2>/dev/null)
        msg_inf "Note: not a 3x-ui-pro install — the address may need manual editing."
    fi
    [[ -n "$port" ]] || port="2053"
    path="${path#/}"; path="${path%/}"
    [[ -n "$path" ]] && path="/${path}/" || path="/"

    local address="$domain" mport=443 hint=""
    if [[ -z "$domain" ]] || ! grep -rq "$domain" /etc/nginx/stream-enabled/ 2>/dev/null; then
        # no SNI router in front: point the master at the panel port directly
        mport="$port"
        address=$(ip route get 8.8.8.8 2>/dev/null | grep -Po -- 'src \K\S*' | head -n1)
        [[ -n "$address" ]] || address="$domain"
    fi
    if [[ -z "$domain" ]] || [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
        hint=" -tls skip"
    fi

    local name country
    if [[ -n "$SLAVE_NAME" ]]; then
        name="$SLAVE_NAME"
    else
        # default label = the server's country (same source users see)
        country=$(curl -fsS --max-time 8 https://ifconfig.co/country 2>/dev/null | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        name="${country:-${label:-$domain}}"
    fi
    # node names feed slave client emails — keep them safe (no spaces/pipes)
    name=$(echo "$name" | tr -d '|' | tr '[:space:]' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
    name="${name:0:32}"
    local spec="${name}|https|${address}|${mport}|${path}|${API_TOKEN}"
    msg_inf "Скопируйте команду ниже и выполните её на MASTER-ноде:"
    echo
    echo "  bash x-ui-node.sh${hint} -node \"${spec}\""
    echo
    msg_inf "Проверка на мастере: bash x-ui-node.sh -list   /   bash x-ui-node.sh -check"
    msg_err "ВАЖНО: токен ротируется при каждом запуске -slave — прошлая команда перестанет работать!"
}

case "$MODE" in
    list)  mode_list ;;
    check) mode_check ;;
    del)   mode_del ;;
    slave) mode_slave ;;
    add)   mode_add ;;
esac