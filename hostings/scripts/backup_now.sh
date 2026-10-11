#!/usr/bin/env bash
set -e
# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
DEBUG_MODE=0
_dbg_args=()
for _a in "$@"; do
    case "$_a" in
        -d|--debug) DEBUG_MODE=1 ;;
        *)          _dbg_args+=("$_a") ;;
    esac
done
set -- ${_dbg_args+"${_dbg_args[@]}"}
unset _a _dbg_args
[ "$DEBUG_MODE" = "1" ] && set -x
# =============================================================================
# The console's "Back up now" button: runs the nightly backup unit once, now.
#
#   backup_now.sh start    start it in the background; refused while it runs
#   backup_now.sh status   one line of JSON for the console
#
# It starts the unit add_docker_volume_backup.sh installed and nothing else, so
# the page can trigger a backup but never choose what it copies or where to.
# A machine without that unit gets {"installed":false} and no button.
# =============================================================================
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

UNIT="docker-volume-backup.service"

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

prop() { systemctl show "$UNIT" --timestamp=unix -p "$1" --value 2>/dev/null; }
installed() { [ "$(prop LoadState)" = "loaded" ]; }
running()   { [ "$(prop ActiveState)" = "activating" ] || [ "$(prop ActiveState)" = "active" ]; }

case "${1:-}" in
    status)
        if ! installed; then echo '{"installed":false}'; exit 0; fi
        last="$(prop ExecMainExitTimestamp)"; last="${last#@}"
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        result="$(prop Result)"
        case "$result" in *[!a-z-]*) result="unknown" ;; esac
        printf '{"installed":true,"running":%s,"last":%s,"result":"%s"}\n' \
            "$(running && echo true || echo false)" "$last" "${result:-unknown}"
        ;;
    start)
        if ! installed; then
            print_error "No backup is installed on this machine ($UNIT)."
            exit 1
        fi
        if running; then
            print_error "A backup is already running. It finishes on its own."
            exit 1
        fi
        systemctl start --no-block "$UNIT"
        print_success "Backup started. It takes a minute or two."
        ;;
    *)
        echo "Usage: $0 start|status" >&2
        exit 2
        ;;
esac
