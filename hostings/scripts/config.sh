#!/usr/bin/env bash
# =============================================================================
# WHICH CONFIG FILE IS IN FORCE. The interface; the answer is a config value.
# test-machine-decisions.md, "Build plan", step 2.
#
#   conf_active </etc/hostings dir>   the path of the file in force, on stdout
#   conf_golive </etc/hostings dir>   the live file Go live would write, on
#                                     stdout: the test file, with every key the
#                                     live file sets keeping the live value and
#                                     MACHINE_IS_LIVE = yes. Returns 1, writing
#                                     nothing, when the live file holds a row or
#                                     is already live, or there is no test file
#
# MACHINE_IS_LIVE in hostings.conf decides:
#
#   yes  hostings.conf
#   no   hostings.test.conf, or hostings.conf when there is no test file
#
# A machine without a test file (every branch but the server) never notices.
# Callers look beside themselves, then in the pipeline clone (the console's
# /usr/local/sbin copies have nothing beside them), then fall back to
# hostings.conf, which only a bare machine with no clone ever reaches:
#
#   . "$SCRIPT_DIR/config.sh" 2>/dev/null \
#       || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
#       || conf_active() { printf '%s/hostings.conf' "$1"; }
# =============================================================================

conf_active() {
    local dir="${1%/}" live
    live="$(grep -E '^[[:space:]]*MACHINE_IS_LIVE[[:space:]]*=' "$dir/hostings.conf" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '\r')"
    live="${live%%#*}"
    live="$(printf '%s' "$live" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ "$live" != "yes" ] && [ -f "$dir/hostings.test.conf" ]; then
        printf '%s/hostings.test.conf' "$dir"
    else
        printf '%s/hostings.conf' "$dir"
    fi
}

conf_golive() {
    local dir="${1%/}"
    [ "$(conf_active "$dir")" = "$dir/hostings.test.conf" ] || return 1
    grep -qE '^[[:space:]]*[^#[:space:]][^=]*\|' "$dir/hostings.conf" && return 1
    printf '# LIVE CONFIG, written by Go live on %s from hostings.test.conf.\n' "$(date '+%Y-%m-%d %H:%M')"
    # The test file's own opening paragraph says TEST, so it is dropped.
    awk '
        function key(l) { sub(/^[ \t]*/, "", l); sub(/[ \t]*=.*/, "", l); return l }
        /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/ { k = key($0) }
        FNR == NR {
            if (k != "" && k != "MACHINE_IS_LIVE" && !(k in keep)) { keep[k] = $0; order[++n] = k }
            k = ""; next
        }
        FNR == 1 && /TEST CONFIG/ { intro = 1 }
        intro { if ($0 ~ /^[ \t]*$/) intro = 0; k = ""; next }
        k == "MACHINE_IS_LIVE" { print "MACHINE_IS_LIVE = yes"; k = ""; next }
        k in keep { if (!(k in done)) print keep[k]; done[k] = 1; k = ""; next }
        { k = ""; print }
        END { for (i = 1; i <= n; i++) if (!(order[i] in done)) print keep[order[i]] }
    ' "$dir/hostings.conf" "$dir/hostings.test.conf"
}
