#!/bin/bash
#################### 3x-ui-pro — multi-node (x-ui-node.sh) #####################
#
# Attach slave 3x-ui panels to the master so a single subscription URL covers
# every server. Run ON THE MASTER (a 3x-ui-pro installed panel):
#
#   bash x-ui-node.sh -node "USA|https|us.example.com|443|/AbCdEf/|TOKEN" \
#                      -node "EU|https|eu.example.com|443|/GhIjKl/|TOKEN"
#
# For every eternal user on the master, the script attaches the user to every
# inbound imported from the slave node; the master then provisions those
# clients to the node, and the existing subscription URL starts emitting
# profiles pointing at the node's address. Nothing on the slave needs manual
# changes — just its API token.
#
# Node spec format (one per -node flag, repeatable):
#   name|scheme|address|port|basePath|apiToken
#     name     unique label, e.g. "USA"
#     scheme   https (default) or http
#     address  hostname or IP only (no scheme, no port, no trailing /)
#     port     the node panel's web port
#     basePath the node panel's web base path, MUST end with '/'
#     apiToken the node's API token — run ONCE on the node:
#              /usr/local/x-ui/x-ui setting -getApiToken true
#
# !!! WARNING: that command ROTATES the token on every call. Fetch it once,
#     paste it here, and do NOT re-run it afterwards or the master will get
#     401s from the node (fix: re-add the node with a fresh token).
#
# Other modes:
#   bash x-ui-node.sh -list                    # nodes on this master
#   bash x-ui-node.sh -check                   # health + client coverage
#   bash x-ui-node.sh -del <name> [...]        # remove node(s) + their inbounds
#   bash x-ui-node.sh -users N                 # attach only first N users
#   bash x-ui-node.sh -tls skip|verify|pin     # TLS verify mode for nodes (default verify)
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

STATE_FILE="/etc/x-ui/3x-ui-pro/install.env"

NODES=()            # "-node" specs
USERS_ARG=""        # -users N (default: all eternal users)
TLS_MODE="verify"   # verify | skip | pin
PIN_SHA=""
MODE="add"          # add | list | check | del

while [[ $# -gt 0 ]]; do
    case "$1" in
        -node)  NODES+=("$2"); shift 2 ;;
        -users) USERS_ARG="$2"; shift 2 ;;
        -tls)   TLS_MODE="$2"; shift 2 ;;
        -pin_sha) PIN_SHA="$2"; shift 2 ;;
        -list)  MODE="list"; shift ;;
        -check) MODE="check"; shift ;;
        -del)   MODE="del"; DEL_NAMES+=("$2"); shift 2 ;;
        *)      shift 1 ;;
    esac
done

# ─── Master panel API (the panel mints a fresh token per call — fetch ONCE) ──
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
parse_spec() { # <spec> -> name scheme address port basePath token (global vars)
    local spec="$1"
    N_NAME=$(echo "$spec" | cut -d'|' -f1)
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
    case "$TLS_MODE" in
        verify|skip|pin) ;;
        *) msg_err "Bad -tls '$TLS_MODE' (verify|skip|pin)"; return 1 ;;
    esac
    return 0
}

node_payload() {
    jq -nc --arg name "$N_NAME" --arg scheme "$N_SCHEME" --arg addr "$N_ADDR" \
        --argjson port "$N_PORT" --arg base "$N_BASE" --arg tok "$N_TOKEN" \
        --arg tls "$TLS_MODE" --arg pin "$PIN_SHA" \
        '{name:$name, remark:"3x-ui-pro node", scheme:$scheme, address:$addr, port:($port|tonumber),
          basePath:$base, apiToken:$tok, enable:true, allowPrivateAddress:true,
          tlsVerifyMode:$tls, pinnedCertSha256:$pin}'
}

# ─── Eternal users on the master ─────────────────────────────────────────────
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

# ─── Flow per inbound protocol (REALITY needs xtls-rprx-vision) ─────────────
flow_for_inbound() { # <inbound-json> -> echo "xtls-rprx-vision" | ""
    local ib="$1" sec
    sec=$(echo "$ib" | jq -r '.streamSettings.security // "none"')
    if [[ "$sec" == "reality" ]]; then echo "xtls-rprx-vision"; else echo ""; fi
}

skip_protocol() { # wireguard/amneziawg peers are per-inbound, not sub clients
    case "$1" in wireguard|amneziawg) return 0 ;; *) return 1 ;; esac
}

# ─── Modes ───────────────────────────────────────────────────────────────────
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
    local name id out ib_ids id2 hid
    for name in "${DEL_NAMES[@]}"; do
        out=$(api GET /nodes/list)
        id=$(echo "$out" | jq -r --arg n "$name" '.obj[]? | select(.name == $n) | .id' | head -n1)
        [[ -n "$id" ]] || { msg_err "Node '$name' not found on the master."; continue; }
        ib_ids=$(api GET /inbounds/list | jq -r --argjson nid "$id" '[.obj[]? | select(.nodeId == $nid) | .id] | join(" ")')
        for id2 in $ib_ids; do
            for hid in $(api GET /hosts/list | jq -r --argjson iid "$id2" '.obj[]? | select(.inboundId == $iid) | .id' 2>/dev/null); do
                api POST "/hosts/del/${hid}" >/dev/null || true
            done
            api POST "/inbounds/del/${id2}" >/dev/null || true
        done
        [[ -n "$ib_ids" ]] && msg_inf "Removed ${ib_ids// /,} inbound(s) (and their hosts) of node '$name'."
        if api POST "/nodes/del/${id}" | api_ok; then
            msg_ok "Node '$name' deleted."
        else
            msg_err "Failed to delete node '$name'."
        fi
    done
}

mode_check() {
    local out n
    out=$(api GET /nodes/list)
    if [[ "$(echo "$out" | jq -r '[.obj[]?] | length')" == "0" ]]; then
        msg_inf "No nodes on this master yet."
        return 0
    fi
    echo "$out" | jq -r '.obj[]? | "\(.name): \(.status) (\(.inboundCount) inbounds, \(.clientCount) clients) latency=\(.latencyMs)ms"'
    local email missing=0
    for email in $(eternal_users_list); do
        for n in $(echo "$out" | jq -r '.obj[]? | .name'); do
            local nid ib_hits
            nid=$(echo "$out" | jq -r --arg n "$n" '.obj[]? | select(.name == $n) | .id' | head -n1)
            ib_hits=$(api GET /inbounds/list | jq -c --argjson nid "$nid" --arg e "$email" \
                '[.obj[]? | select(.nodeId == $nid and (.settings | contains($e))) | .id] | length')
            if [[ "$ib_hits" == "0" ]]; then
                msg_err "  client '$email' is NOT on node '$n' (no matching inbound settings)"
                missing=1
            fi
        done
    done
    [[ "$missing" == "0" ]] && msg_ok "All eternal users are attached to every node."
}

# ─── Add nodes + attach users ────────────────────────────────────────────────
mode_add() {
    local spec node_id
    local -A NODE_IDS=()
    local -A NODE_HOSTS=()

    [[ ${#NODES[@]} -gt 0 ]] || { msg_err "No -node specs given (see header)."; exit 1; }

    for spec in "${NODES[@]}"; do
        parse_spec "$spec" || exit 1
        NODE_HOSTS["$N_NAME"]="$N_ADDR"
        local existing
        existing=$(api GET /nodes/list | jq -r --arg n "$N_NAME" '.obj[]? | select(.name == $n) | .id' | head -n1)
        if [[ -n "$existing" ]]; then
            msg_inf "→ Node '$N_NAME' already exists (id=$existing) — reusing it, no duplicate created."
            NODE_IDS["$N_NAME"]="$existing"
            continue
        fi
        msg_inf "→ Adding node '$N_NAME' (${N_SCHEME}://${N_ADDR}:${N_PORT}${N_BASE})..."
        local payload resp
        payload=$(node_payload)
        resp=$(api POST /nodes/test -H 'Content-Type: application/json' -d "$payload")
        if ! echo "$resp" | api_ok; then
            msg_err "Node '$N_NAME' unreachable: $(echo "$resp" | jq -r '.msg // "unknown error"')"
            continue
        fi
        resp=$(api POST /nodes/add -H 'Content-Type: application/json' -d "$payload")
        if echo "$resp" | api_ok; then
            node_id=$(echo "$resp" | jq -r '.obj.id // empty')
            [[ -n "$node_id" ]] || node_id=$(api GET /nodes/list | jq -r --arg n "$N_NAME" '.obj[]? | select(.name == $n) | .id' | head -n1)
            NODE_IDS["$N_NAME"]="$node_id"
            msg_ok "Node '$N_NAME' added (id=$node_id)."
        else
            msg_err "Failed to add node '$N_NAME': $(echo "$resp" | jq -r '.msg // "unknown error"')"
        fi
    done

    # Wait for heartbeat + inbound import (up to 90s).
    local waited=0 ok=0
    while (( waited < 90 )); do
        ok=1
        for name in "${!NODE_IDS[@]}"; do
            local nid ib_count
            nid="${NODE_IDS[$name]}"
            ib_count=$(api GET /inbounds/list | jq -r --argjson nid "$nid" '[.obj[]? | select(.nodeId == $nid)] | length')
            [[ "$ib_count" -gt 0 ]] || ok=0
        done
        [[ "$ok" == "1" ]] && break
        sleep 5; waited=$((waited + 5))
    done
    [[ "$ok" == "1" ]] || { msg_err "Node inbounds were not imported within 90s — check nodes/list and the panel log."; exit 1; }
    msg_ok "Node inbounds are imported into the master."

    # Host overrides: node TCP inbounds listen on 127.0.0.1 behind the node's
    # nginx SNI router, so their share links must advertise the node's :443.
    # REALITY hosts keep security "same" (SNI/keys come from the inbound);
    # the TLS-fronted ones (ws/grpc/httpupgrade/xhttp/trojan/vmess) get "tls".
    # Own-port protocols (kcp/tuic/hysteria/shadowsocks) keep their ports and
    # need no host; wireguard/amneziawg/mtproto are skipped entirely.
    local name
    for name in "${!NODE_IDS[@]}"; do
        local nid ibs reality_ids tls_ids ib proto net sec id3
        nid="${NODE_IDS[$name]}"
        ibs=$(api GET /inbounds/list | jq -c --argjson nid "$nid" '[.obj[]? | select(.nodeId == $nid)]')
        reality_ids=""; tls_ids=""
        while IFS= read -r ib; do
            [[ -z "$ib" ]] && continue
            proto=$(echo "$ib" | jq -r '.protocol')
            net=$(echo "$ib" | jq -r '.streamSettings.network // "tcp"')
            sec=$(echo "$ib" | jq -r '.streamSettings.security // "none"')
            case "$proto" in
                wireguard|amneziawg|mtproto|tuic|hysteria|shadowsocks) continue ;;
            esac
            [[ "$net" == "kcp" ]] && continue
            id3=$(echo "$ib" | jq -r '.id')
            if [[ "$sec" == "reality" ]]; then
                reality_ids="${reality_ids},${id3}"
            else
                tls_ids="${tls_ids},${id3}"
            fi
        done <<< "$(echo "$ibs" | jq -c '.[]')"

        add_hosts() { # <security> <space-separated inbound ids>
            local sec2="$1" ids2="$2" payload
            [[ -n "$ids2" ]] || return 0
            payload=$(jq -nc --arg r "3x-ui-pro node ${name}" --arg a "${NODE_HOSTS[$name]}" \
                --arg s "$sec2" \
                --argjson ids "$(echo "$ids2" | tr ',' '\n' | sed '/^$/d' | jq -R 'tonumber' | jq -s -c '.')" \
                '{inboundIds:$ids, hosts:[$a], remark:$r, sortOrder:0, security:$s, sni:"",
                  fingerprint:"firefox", allowInsecure:false, pinnedPeerCertSha256:"", alpn:""}')
            api POST /hosts/add -H 'Content-Type: application/json' -d "$payload" | api_ok \
                || msg_err "  failed to add host (security=$sec2) for node '$name'"
        }
        add_hosts "same" "$reality_ids"
        add_hosts "tls" "$tls_ids"
        msg_ok "Host overrides for node '$name' added (TCP inbounds advertised via ${NODE_HOSTS[$name]}:443)."
    done

    # Attach every eternal user to the node inbounds (REALITY gets the flow).
    local email attached=0
    for email in $(eternal_users_list); do
        for name in "${!NODE_IDS[@]}"; do
            local nid ibs id2 flow reality_ids other_ids ib
            nid="${NODE_IDS[$name]}"
            ibs=$(api GET /inbounds/list | jq -c --argjson nid "$nid" '[.obj[]? | select(.nodeId == $nid)]')
            reality_ids=""; other_ids=""
            while IFS= read -r ib; do
                [[ -z "$ib" ]] && continue
                skip_protocol "$(echo "$ib" | jq -r '.protocol')" && continue
                id2=$(echo "$ib" | jq -r '.id')
                flow=$(flow_for_inbound "$ib")
                if [[ "$flow" == "xtls-rprx-vision" ]]; then
                    reality_ids="${reality_ids},${id2}"
                else
                    other_ids="${other_ids},${id2}"
                fi
            done <<< "$(echo "$ibs" | jq -c '.[]')"

            attach_ids() { # <flow> <space-separated inbound ids>
                local f="$1" ids="$2" payload sub
                [[ -n "$ids" ]] || return 0
                sub="${SUBID_BASE}-${email##*-}"
                payload=$(jq -nc --arg e "$email" --arg sub "$sub" --arg flow "$f" \
                    --argjson ids "$(echo "$ids" | tr ',' '\n' | sed '/^$/d' | jq -R 'tonumber' | jq -s -c '.')" \
                    '{client:{email:$e, subId:$sub, totalGB:0, expiryTime:0, enable:true, limitIp:0, flow:$flow, comment:"3x-ui-pro multi-node"}, inboundIds:$ids}')
                api POST /clients/add -H 'Content-Type: application/json' -d "$payload" | api_ok \
                    || msg_err "  failed to attach '$email' (flow='$f')"
            }
            attach_ids "xtls-rprx-vision" "$reality_ids"
            attach_ids "" "$other_ids"
            attached=1
        done
    done
    [[ "$attached" == "1" ]] && msg_ok "Eternal users attached to node inbounds — subscription now covers every node."
    local first
    first=$(eternal_users_list | head -n1)
    msg_inf "Subscription (unchanged URL, now multi-node): https://${DOMAIN}/${SUB_PATH}/${SUBID_BASE}-1"
}

case "$MODE" in
    list)  mode_list ;;
    check) mode_check ;;
    del)   mode_del ;;
    add)   mode_add ;;
esac