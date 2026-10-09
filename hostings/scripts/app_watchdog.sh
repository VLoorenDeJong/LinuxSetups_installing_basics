#!/usr/bin/env bash
set -e

# =============================================================================
# Restarts an app that runs but no longer answers.
#
#   app_watchdog.sh        one pass over every running app-* unit
#
# Run every minute by watchdog-apps.timer (written by add_app_services.sh).
# "Answers" is deploy_app.sh's rule: any HTTP reply that is not a 5xx. An app
# is restarted after FAILS_BEFORE_RESTART misses in a row, and never within
# GRACE_SECONDS of its start, so a deploy or a slow first start is left alone.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

# Prompts. print_action cannot be one: it ends with a newline.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}"; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only: see the timeout regimes above.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

FAILS_BEFORE_RESTART=3
GRACE_SECONDS=300
PROBE_TIMEOUT=10
STATE_DIR="/run/watchdog-apps"

[ "$EUID" -eq 0 ] || { print_error "This needs root: it restarts units."; exit 2; }
install -d -m 700 "$STATE_DIR"

now="$(date +%s)"
for unit in $(systemctl list-units 'app-*.service' --state=active --plain --no-legend | awk '{print $1}'); do
    count_file="$STATE_DIR/$unit"
    port="$(systemctl cat "$unit" 2>/dev/null | grep -m1 -oE '(localhost|127\.0\.0\.1):[0-9]+' | cut -d: -f2)"
    [ -n "$port" ] || continue

    started="$(systemctl show -p ActiveEnterTimestamp --value "$unit")"
    started="$(date -d "$started" +%s 2>/dev/null || echo "$now")"
    if [ $((now - started)) -lt "$GRACE_SECONDS" ]; then
        rm -f "$count_file"
        continue
    fi

    code="$(curl -s -o /dev/null -m "$PROBE_TIMEOUT" -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)" || true
    case "$code" in
        2??|3??|4??) rm -f "$count_file"; continue ;;
    esac

    fails=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
    if [ "$fails" -lt "$FAILS_BEFORE_RESTART" ]; then
        echo "$fails" > "$count_file"
        print_action "$unit: no answer on port $port (HTTP ${code:-none}), miss $fails of $FAILS_BEFORE_RESTART"
        continue
    fi

    rm -f "$count_file"
    print_action "$unit: no answer on port $port for $fails minutes, restarting it"
    systemctl restart "$unit" || print_error "$unit: restart failed"
done
