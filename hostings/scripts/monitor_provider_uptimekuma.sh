#!/usr/bin/env bash
# =============================================================================
# Uptime Kuma behind monitor.sh. The only file that logs in to Kuma.
#
# Kuma has no official API for adding monitors, so monitor_sync drives its
# socket.io API through the unofficial uptime-kuma-api2 wrapper, in the venv
# add_monitor_client.sh makes. A Kuma upgrade can break that wrapper.
#
# Secrets go to Python and curl on stdin, never as an argument or in the
# environment:
#   session token /etc/uptime-kuma/token on the Kuma machine (root, 0600),
#                 written by add_uptime_kuma.sh; no expiry, dies with a
#                 password change (--renew-token)                (monitor_sync)
#   API key       the vault item "Uptime Kuma API key"           (monitor_states)
# =============================================================================

MONITOR_VENV="${MONITOR_VENV:-/opt/hosting-monitor/venv}"
MONITOR_TOKEN_FILE="${MONITOR_TOKEN_FILE:-/etc/uptime-kuma/token}"

_kuma_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }

_kuma_secrets() {
    [ "${SECRET_READY:-0}" = "1" ] || {
        local d; d="$(_kuma_dir)"
        export SECRET_OPTIONAL=1
        # shellcheck source=/dev/null
        . "$d/secret_store.sh" >/dev/null 2>&1 || true
    }
    [ "${SECRET_READY:-0}" = "1" ]
}

# field of an entry's own login section: username or password
_kuma_field() {
    secret_entry_get "$1" "" 2>/dev/null | awk -F'\t' -v f="$2" '$1 == "" && $2 == f { print $3; exit }'
}

monitor_preflight() {
    local bad=0
    if [ ! -x "$MONITOR_VENV/bin/python" ]; then
        echo "No Kuma client venv at $MONITOR_VENV: sudo bash add_monitor_client.sh"; bad=1
    fi
    if [ ! -s "$MONITOR_TOKEN_FILE" ]; then
        echo "No Kuma session token at $MONITOR_TOKEN_FILE: monitors are synced on the machine running Kuma, where add_uptime_kuma.sh writes it."; bad=1
    fi
    if ! curl -s -o /dev/null --max-time 5 "$MONITOR_URL"; then
        echo "Kuma does not answer at $MONITOR_URL"; bad=1
    fi
    return $bad
}

# Tracing is off in both: the secrets sit in variables, and set -x prints those.
monitor_sync() {
    local prefix="$1" token rc=0 xt
    { xt=$-; set +x; } 2>/dev/null
    token="$(head -n 1 "$MONITOR_TOKEN_FILE" 2>/dev/null)"
    if [ -n "$token" ]; then
        { printf '%s\n' "$token"; cat; } \
            | "$MONITOR_VENV/bin/python" -I "$(_kuma_dir)/monitor_uptimekuma.py" sync "$MONITOR_URL" "$prefix" \
            || rc=$?
    else
        print_error "No Kuma session token in $MONITOR_TOKEN_FILE."
        rc=1
    fi
    unset token
    if [[ $xt == *x* ]]; then set -x; fi
    return $rc
}

# Kuma's /metrics: monitor_status{monitor_name="..",...} 0 down, 1 up,
# 2 pending, 3 maintenance. The key goes to curl as a config file on stdin.
# The key is kept for the life of the caller (the status publisher asks every
# minute), and after a refusal the vault is asked again at most every 10 min.
_KUMA_KEY=""
_KUMA_KEY_NEXT=0
monitor_states() {
    local rc=0 xt body now
    { xt=$-; set +x; } 2>/dev/null
    now="$(date +%s)"
    if [ -z "$_KUMA_KEY" ] && [ "$now" -ge "$_KUMA_KEY_NEXT" ]; then
        _KUMA_KEY_NEXT=$((now + 600))
        _kuma_secrets && _KUMA_KEY="$(_kuma_field "Uptime Kuma API key" password)"
    fi
    if [ -n "$_KUMA_KEY" ] \
       && body="$(printf 'user = ":%s"\n' "$_KUMA_KEY" | curl -sf --max-time 10 -K - "$MONITOR_URL/metrics")"; then
        printf '%s\n' "$body" \
          | sed -n 's/^monitor_status{.*monitor_name="\([^"]*\)".*} \([0-9]\).*/\1\t\2/p' \
          | awk -F'\t' 'BEGIN { s[0]="down"; s[1]="up"; s[2]="pending"; s[3]="maintenance" }
                        { print $1 "\t" (($2 in s) ? s[$2] : "unknown") }'
    else
        # A refused key is dropped, so a rotated one is picked up.
        _KUMA_KEY=""
        rc=1
    fi
    if [[ $xt == *x* ]]; then set -x; fi
    return $rc
}
