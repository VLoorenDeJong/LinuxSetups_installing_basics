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
# The console's "Restore" button: puts every folder in a dropped-in backup copy
# back, from its newest snapshot.
#
#   restore_now.sh status   one line of JSON for the console
#   restore_now.sh start    runs the restore in the background (unit restore-now)
#   restore_now.sh run      the restore itself; what `start` runs
#
# THE COPY IS DROPPED IN, NEVER CHOSEN BY THE PAGE: the docker-volume-backup
# unit's RESTORE_DROP_DIR (its own share), holding a copy of the repository at
# any depth up to 3. No RESTORE_DROP_DIR, no Restore button.
# It must open with this machine's backup password, the one from
# restic_password.sh, so a foreign copy is refused rather than
# restored.
#
# WHAT A RESTORE DOES: stops every running container, moves each folder the
# snapshot holds aside as <folder>.before-restore-<time>, restores it, starts
# the same containers again, then runs each executable in /etc/restore-now.d
# (an app whose data needs more than its files, such as a database dump).
# Named Docker volumes are left alone. The moved-aside folders stay until
# deleted by hand: they are the way back.
# =============================================================================
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

BACKUP_UNIT="docker-volume-backup.service"
RESTORE_UNIT="restore-now"
STATE_DIR="/var/lib/restore-now"
HOOK_DIR="/etc/restore-now.d"
SKIP_PATH="/var/lib/docker/volumes"

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

unit_env() {
    systemctl show "$BACKUP_UNIT" -p Environment --value 2>/dev/null \
        | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
LIVE_REPO="$(unit_env RESTIC_REPOSITORY)"
# The runtime copy, as the backup unit uses: this file runs from /usr/local/sbin.
PASSWORD_HELPER="/usr/local/lib/linuxbasics/hostings/scripts/restic_password.sh"
PASSWORD_CMD="/bin/bash $PASSWORD_HELPER get docker-backup-password"
# Its own share, never beside the live repository: a copy dropped one folder
# too high there overwrote the live repository's config on 2026-10-13.
DROP_DIR="$(unit_env RESTORE_DROP_DIR)"

# A restic repository is a folder holding a `config` file and a `keys` folder.
find_copy() {
    [ -d "$DROP_DIR" ] || return 1
    local cfg
    cfg="$(find "$DROP_DIR" -mindepth 1 -maxdepth 4 -type f -name config -path '*/config' 2>/dev/null \
        | while read -r c; do [ -d "$(dirname "$c")/keys" ] && { dirname "$c"; break; }; done)"
    [ -n "$cfg" ] && printf '%s' "$cfg"
}
restic_copy() {
    if [ -n "${PW_FILE:-}" ]; then restic -r "$COPY" --password-file "$PW_FILE" --no-cache "$@"
    else restic -r "$COPY" --password-command "$PASSWORD_CMD" --no-cache "$@"; fi
}
running() {
    local s; s="$(systemctl show "$RESTORE_UNIT" -p ActiveState --value 2>/dev/null)"
    [ "$s" = "active" ] || [ "$s" = "activating" ]
}

case "${1:-}" in
    status)
        last="$(cat "$STATE_DIR/last.json" 2>/dev/null || echo 'null')"
        if [ -z "$LIVE_REPO" ] || [ ! -f "$PASSWORD_HELPER" ] || ! command -v restic >/dev/null 2>&1; then
            echo '{"installed":false}'; exit 0
        fi
        run="$(running && echo true || echo false)"
        COPY="$(find_copy || true)"
        if [ -z "$COPY" ]; then
            printf '{"installed":true,"copy":false,"running":%s,"last":%s}\n' "$run" "$last"; exit 0
        fi
        when="$(restic_copy snapshots --latest 1 --json 2>/dev/null \
            | python3 -c 'import json,sys,re,datetime
s=json.load(sys.stdin)
print(int(datetime.datetime.fromisoformat(re.sub(r"\.\d+", "", s[-1]["time"]).replace("Z", "+00:00")).timestamp()) if s else "")' 2>/dev/null || true)"
        if [ -z "$when" ]; then
            printf '{"installed":true,"copy":true,"opens":false,"running":%s,"last":%s}\n' "$run" "$last"; exit 0
        fi
        printf '{"installed":true,"copy":true,"opens":true,"when":%s,"running":%s,"last":%s}\n' "$when" "$run" "$last"
        ;;

    start)
        COPY="$(find_copy || true)"
        [ -n "$DROP_DIR" ] || { print_error "No drop folder set up. Re-run add_docker_volume_backup.sh."; exit 1; }
        [ -n "$COPY" ] || { print_error "No backup copy in $DROP_DIR."; exit 1; }
        running && { print_error "A restore is already running."; exit 1; }
        if [ "$(systemctl show "$BACKUP_UNIT" -p ActiveState --value)" = "activating" ]; then
            print_error "A backup is running. Restore once it has finished."; exit 1
        fi
        systemctl reset-failed "$RESTORE_UNIT" >/dev/null 2>&1 || true
        systemd-run --quiet --unit="$RESTORE_UNIT" --collect "$0" run
        print_success "Restore started. Every app stops for a few minutes."
        ;;

    run)
        install -d -m 0700 "$STATE_DIR"
        STAMP="$(date +%Y%m%d-%H%M%S)"
        finish() {
            printf '{"at":%s,"ok":%s,"copy":"%s"}\n' "$(date +%s)" "$1" "${COPY:-}" > "$STATE_DIR/last.json"
        }
        COPY="$(find_copy || true)"
        [ -n "$COPY" ] || { print_error "No backup copy in $DROP_DIR."; finish false; exit 1; }
        SNAP_JSON="$(restic_copy snapshots --latest 1 --json)" || { print_error "The copy does not open with this machine's backup password."; finish false; exit 1; }
        mapfile -t PATHS < <(printf '%s' "$SNAP_JSON" | python3 -c 'import json,sys
s=json.load(sys.stdin)
print("\n".join(s[-1]["paths"]) if s else "")')
        SNAP="$(printf '%s' "$SNAP_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["short_id"])')"
        print_status "Restoring snapshot $SNAP from $COPY"

        # Read now: the vault can be a container (1Password Connect) that the
        # stop below takes away.
        PW_FILE="$(mktemp -p /run restore-now-pw.XXXXXX)"
        WAS_UNITS=() WAS_RUNNING=() RESTARTED=0
        restart_all() {
            RESTARTED=1
            local rc=0
            [ ${#WAS_RUNNING[@]} -eq 0 ] || docker start "${WAS_RUNNING[@]}" >/dev/null || { print_error "Some containers did not start again."; rc=1; }
            [ ${#WAS_UNITS[@]} -eq 0 ] || systemctl start "${WAS_UNITS[@]}" || { print_error "Some app units did not start again."; rc=1; }
            return "$rc"
        }
        # A crash after the stop must not leave every app down.
        trap 'rm -f "$PW_FILE"; [ "$RESTARTED" = 1 ] || restart_all || true' EXIT
        $PASSWORD_CMD > "$PW_FILE" 2>/dev/null && [ -s "$PW_FILE" ] \
            || { print_error "No backup password, so nothing was stopped or moved."; finish false; exit 1; }

        # App containers are units' `docker run --rm`: stopped through docker,
        # they are gone, and their unit starts a new one on an empty folder.
        mapfile -t WAS_UNITS < <(systemctl list-units --type=service --state=active --no-legend --plain 'app-*.service' | awk '{print $1}')
        [ ${#WAS_UNITS[@]} -eq 0 ] || { print_status "Stopping ${#WAS_UNITS[@]} app unit(s)."; systemctl stop "${WAS_UNITS[@]}"; }
        mapfile -t WAS_RUNNING < <(docker ps -q 2>/dev/null)
        if [ ${#WAS_RUNNING[@]} -gt 0 ]; then
            print_status "Stopping ${#WAS_RUNNING[@]} other container(s)."
            docker stop "${WAS_RUNNING[@]}" >/dev/null
        fi
        ok=true
        for p in "${PATHS[@]}"; do
            case "$p" in /*) ;; *) continue ;; esac
            [ "$p" = "$SKIP_PATH" ] && { print_status "Skipping $p: named volumes are left alone."; continue; }
            if [ -e "$p" ]; then
                mv -- "$p" "$p.before-restore-$STAMP"
                print_status "Moved $p aside to $p.before-restore-$STAMP"
            fi
            if restic_copy restore "$SNAP" --target / --include "$p" >/dev/null; then
                print_success "Restored $p"
            else
                print_error "Restoring $p failed, so its old folder is put back."
                [ -e "$p" ] && mv -- "$p" "$p.failed-restore-$STAMP"
                [ -e "$p.before-restore-$STAMP" ] && mv -- "$p.before-restore-$STAMP" "$p"
                ok=false
            fi
        done
        restart_all || ok=false
        if [ -d "$HOOK_DIR" ]; then
            for h in "$HOOK_DIR"/*; do
                [ -f "$h" ] && [ -x "$h" ] || continue
                print_status "After the restore: $(basename "$h")"
                "$h" || { print_error "$(basename "$h") failed."; ok=false; }
            done
        fi
        finish "$ok"
        if [ "$ok" = true ]; then
            print_success "Restore done. The old folders are kept as *.before-restore-$STAMP."
        else
            print_action "Restore finished with errors: journalctl -u $RESTORE_UNIT"
            exit 1
        fi
        ;;

    *)
        echo "Usage: $0 start|status" >&2
        exit 2
        ;;
esac
