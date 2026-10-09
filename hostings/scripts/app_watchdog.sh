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

FAILS_BEFORE_RESTART=3
GRACE_SECONDS=300
PROBE_TIMEOUT=10
STATE_DIR="/run/watchdog-apps"

[ "$EUID" -eq 0 ] || { echo "This needs root: it restarts units." >&2; exit 2; }
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
        echo "$unit: no answer on port $port (HTTP ${code:-none}), miss $fails of $FAILS_BEFORE_RESTART"
        continue
    fi

    rm -f "$count_file"
    echo "$unit: no answer on port $port for $fails minutes, restarting it"
    systemctl restart "$unit" || echo "$unit: restart failed"
done
