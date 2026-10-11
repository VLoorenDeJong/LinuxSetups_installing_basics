#!/usr/bin/env bash
# =============================================================================
# Uptime Kuma behind monitor.sh. The only file that logs in to Kuma.
#
# Kuma has no official API for adding monitors, so monitor_sync drives its
# socket.io API through the unofficial uptime-kuma-api2 wrapper, in the venv
# add_monitor_client.sh makes. A Kuma upgrade can break that wrapper.
#
# Secrets come from the secret store and go to Python on stdin, never as an
# argument or in the environment:
#   "Uptime Kuma admin"    Login: username, password      (monitor_sync)
#   "Uptime Kuma API key"  password                       (monitor_states)
# =============================================================================

MONITOR_VENV="${MONITOR_VENV:-/opt/hosting-monitor/venv}"

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
    if ! _kuma_secrets; then
        echo "The secret store is not reachable, so the Kuma login cannot be read."; bad=1
    elif [ -z "$(_kuma_field "Uptime Kuma admin" password)" ]; then
        echo "No 'Uptime Kuma admin' item in the vault: it is made by add_uptime_kuma.sh on the machine running Kuma."; bad=1
    fi
    if ! curl -s -o /dev/null --max-time 5 "$MONITOR_URL"; then
        echo "Kuma does not answer at $MONITOR_URL"; bad=1
    fi
    return $bad
}

# Tracing is off in both: the secrets sit in variables, and set -x prints those.
monitor_sync() {
    local prefix="$1" user pass rc=0 xt
    { xt=$-; set +x; } 2>/dev/null
    if _kuma_secrets; then
        user="$(_kuma_field "Uptime Kuma admin" username)"
        pass="$(_kuma_field "Uptime Kuma admin" password)"
        { printf '%s\n%s\n' "$user" "$pass"; cat; } \
            | "$MONITOR_VENV/bin/python" -I "$(_kuma_dir)/monitor_uptimekuma.py" sync "$MONITOR_URL" "$prefix" \
            || rc=$?
    else
        print_error "Secret store not reachable, so the Kuma login cannot be read."
        rc=1
    fi
    unset user pass
    if [[ $xt == *x* ]]; then set -x; fi
    return $rc
}

# Kuma's /metrics: monitor_status{monitor_name="..",...} 0 down, 1 up,
# 2 pending, 3 maintenance. The key goes to curl as a config file on stdin.
monitor_states() {
    local key="" rc=0 xt
    { xt=$-; set +x; } 2>/dev/null
    _kuma_secrets && key="$(_kuma_field "Uptime Kuma API key" password)"
    if [ -n "$key" ]; then
        printf 'user = ":%s"\n' "$key" \
          | curl -s --max-time 10 -K - "$MONITOR_URL/metrics" \
          | sed -n 's/^monitor_status{.*monitor_name="\([^"]*\)".*} \([0-9]\).*/\1\t\2/p' \
          | awk -F'\t' 'BEGIN { s[0]="down"; s[1]="up"; s[2]="pending"; s[3]="maintenance" }
                        { print $1 "\t" (($2 in s) ? s[$2] : "unknown") }'
    else
        rc=1
    fi
    unset key
    if [[ $xt == *x* ]]; then set -x; fi
    return $rc
}
