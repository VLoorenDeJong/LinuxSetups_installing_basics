#!/usr/bin/env bash
# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it. Silent there instead.
redraw() { [ -t 1 ] || return 0; printf "$@"; }
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
# The nightly encrypted copy of every Docker volume.
#
# Item 140 point 8: all container volumes go in the backups. That is every
# volume on the machine, not only an application row's: Portainer's own, and
# anything added through Portainer later, is data nobody else copies.
#
#   /var/lib/docker/volumes   where the daemon keeps NAMED volumes, root-only
#   DOCKER_BACKUP_PATHS       bind mounts, which are a container's data just as
#                             much as a named volume is. On 2026-09-17 this
#                             machine had ZERO named volumes and Portainer kept
#                             everything it knows in /opt/portainer/data, so a
#                             backup of the volumes directory alone would have
#                             copied nothing at all.
#   DOCKER_BACKUP_REPO        an encrypted restic repository under backup_files,
#                             which a file server on the LAN already copies off
#                             the machine
#
# restic and not a tar of each volume, for the same reason the mail store uses
# it: it writes only what changed, and it is encrypted before it is written, so
# it is safe under a share that is `guest ok = yes`.
#
# The volumes are read from disk rather than through a helper container, so a
# stopped container's volume is copied too and nothing depends on an image
# being pullable. Containers are NOT stopped: a database being written during
# the copy is captured mid-write, exactly as the mail store is.
#
# The repository password is printed ONCE, on the run that creates it, and must
# go into a password vault. The copy on this machine dies with the machine.
#
# Safe to re-run: an existing repository, password and timer are left alone.
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    redraw '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. A restic
# write killed halfway is worse than a slow one.
show_spinner_watch_only() {
    local message="$1"
    shift
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local log
    log="$(mktemp)"

    if [ "${DEBUG_MODE:-0}" = "1" ]; then
        "$@" 2>&1 | tee "$log"
        local rc=${PIPESTATUS[0]}
        rm -f "$log"
        return "$rc"
    fi

    "$@" >"$log" 2>&1 &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        spin_tick "$message" || break
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'

    if [ "$exit_code" -ne 0 ]; then
        print_error "$message failed (exit $exit_code). Last 20 lines:"
        tail -n 20 "$log"
        print_action "Full log: $log"
        return "$exit_code"
    fi

    rm -f "$log"
    return 0
}

export DEBIAN_FRONTEND=noninteractive

DRY_RUN=0
ARG_REPO=""
ARG_TIME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1; shift ;;
        # A missing value would make `shift 2` fail under set -e, which exits
        # with no message at all.
        --backup-repo)  [ -n "${2:-}" ] || { print_error "--backup-repo needs a path."; exit 2; }
                        ARG_REPO="$2"; shift 2 ;;
        --at)           [ -n "${2:-}" ] || { print_error "--at needs a systemd OnCalendar value, for example 03:00."; exit 2; }
                        ARG_TIME="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--backup-repo <path>] [--at <OnCalendar>]"
            exit 0 ;;
        *) print_error "Unknown option: $1"; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null \
        | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${v:-$2}"
}

VOLUME_DIR="/var/lib/docker/volumes"
EXTRA_PATHS="$(conf_get DOCKER_BACKUP_PATHS '/opt/portainer/data')"
# Where docker rows keep their /data. Always copied, so a config list that
# forgets it cannot leave the apps' own files out of the backup.
DOCKER_DATA_ROOT="$(conf_get DOCKER_DATA_ROOT /srv/docker_apps)"
case " $EXTRA_PATHS " in *" $DOCKER_DATA_ROOT "*) ;; *) EXTRA_PATHS="$EXTRA_PATHS $DOCKER_DATA_ROOT" ;; esac
BACKUP_REPO="${ARG_REPO:-$(conf_get DOCKER_BACKUP_REPO '')}"
BACKUP_AT="${ARG_TIME:-$(conf_get DOCKER_BACKUP_AT '03:00')}"
PASSWORD_FILE="$(conf_get DOCKER_BACKUP_PASSWORD_FILE /root/.docker_backup_password)"
KEEP_DAILY="$(conf_get DOCKER_BACKUP_KEEP_DAILY 7)"
KEEP_WEEKLY="$(conf_get DOCKER_BACKUP_KEEP_WEEKLY 4)"

SERVICE_FILE="/etc/systemd/system/docker-volume-backup.service"
TIMER_FILE="/etc/systemd/system/docker-volume-backup.timer"

# Resolve the account the machine belongs to, the same chain add_mail_store.sh
# uses. The repository is owned by it so the file server's SMB pull, which
# lands as this user, can read it. Guessing from the parent directory's owner
# fails on a fresh machine, where root created that directory a moment ago and
# the whole off-machine copy then silently does not happen.
if [ -n "${APP_USER:-}" ]; then
    RUN_USER="$APP_USER"
elif [ -f /etc/manageserver-installer-user ]; then
    RUN_USER="$(cat /etc/manageserver-installer-user)"
elif [ -n "${SUDO_USER:-}" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(logname 2>/dev/null || whoami)"
fi
# The group the SMB guest account reads and restores through, so the share
# never has to act as the machine's own account.
BACKUP_GROUP="$(conf_get BACKUP_READ_GROUP "$RUN_USER")"

print_header "Nightly copy of the Docker volumes"
print_status "Volumes:     $VOLUME_DIR"
print_status "Also:        ${EXTRA_PATHS:-<nothing>}"
print_status "Encrypted:   ${BACKUP_REPO:-<not set>}"
print_status "Every night: $BACKUP_AT"
print_status "Keeping:     $KEEP_DAILY daily, $KEEP_WEEKLY weekly"

# =============================================================================
# Pre-flight: everything that would stop this run, before the first write
# =============================================================================
ERRORS=()

[ "$EUID" -eq 0 ] || ERRORS+=("This needs root: it reads $VOLUME_DIR and writes units.")
[ -n "$BACKUP_REPO" ] || ERRORS+=("DOCKER_BACKUP_REPO is not set in $SITES_CONF")
id "$RUN_USER" >/dev/null 2>&1 \
    || ERRORS+=("Resolved user '$RUN_USER' does not exist. Set it: sudo env APP_USER=<name> $0")
[ -d "$VOLUME_DIR" ] \
    || ERRORS+=("$VOLUME_DIR does not exist, so the unit would fail every night.")
# The list is space separated and goes into ExecStart unquoted, so a path
# containing a space would arrive as two arguments and the unit would silently
# back up the wrong thing. Every entry has to be absolute, which is how that
# case is caught rather than accepted.
for p in $EXTRA_PATHS; do
    case "$p" in
        /*) ;;
        *)  ERRORS+=("DOCKER_BACKUP_PATHS entry '$p' is not an absolute path. Paths must not contain spaces.") ;;
    esac
done
case "$BACKUP_REPO" in
    /*|"") ;;
    *) ERRORS+=("DOCKER_BACKUP_REPO must be an absolute path, not '$BACKUP_REPO'") ;;
esac

if [ -x "$REPO_ROOT/install_scripts/check_docker.sh" ]; then
    bash "$REPO_ROOT/install_scripts/check_docker.sh" --quiet \
        || ERRORS+=("Docker is not usable here. Run LinuxBasics/install_scripts/check_docker.sh to see why.")
elif ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("docker is not installed, so there are no volumes to copy.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Cannot continue:"
    for e in "${ERRORS[@]}"; do echo "   - $e"; done
    exit 1
fi

VOLUME_COUNT="$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')"
print_info "$VOLUME_COUNT named volume(s) on this machine right now."

# A path in the list that does not exist yet is skipped rather than failing the
# unit every night. It is reported, because the usual cause is a renamed data
# directory and the backup would then be quietly copying nothing.
SOURCES=("$VOLUME_DIR")
# Made now rather than by the first docker row, so it is in the unit from the start.
[ "$DRY_RUN" -eq 1 ] || install -d -m 750 "$DOCKER_DATA_ROOT"
for p in $EXTRA_PATHS; do
    if [ -d "$p" ]; then
        SOURCES+=("$p")
    else
        print_action "DOCKER_BACKUP_PATHS names $p, which does not exist. It is not backed up."
    fi
done
print_info "Copying: ${SOURCES[*]}"

# =============================================================================
# The timer.
#
# `forget` runs in the same unit, without --prune. Dropping the metadata is
# cheap, and reclaiming the space is not, so pruning stays a deliberate manual
# step: `restic prune`.
#
# backingFsBlockDev is a device node the overlay driver leaves in each volume
# directory; restic cannot read it and would report a failure every night.
# =============================================================================
NEW_SERVICE="$(cat <<EOF
# Generated by add_docker_volume_backup.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
[Unit]
Description=Encrypted off-machine copy of every Docker volume
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
Environment=RESTIC_PASSWORD_FILE=${PASSWORD_FILE}
Environment=RESTIC_REPOSITORY=${BACKUP_REPO}
# systemd gives no HOME, so without this restic runs uncached and says so nightly.
Environment=RESTIC_CACHE_DIR=/var/cache/restic
ExecStart=/usr/bin/restic backup --quiet --tag docker-volumes \\
    --exclude backingFsBlockDev ${SOURCES[*]}
ExecStart=/usr/bin/restic forget --quiet --tag docker-volumes \\
    --keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY}
# root writes tonight's pack files, so without this the repository fills with
# root-owned files inside a 0700 directory and the file server's SMB pull
# quietly stops seeing anything newer than install day.
ExecStartPost=/bin/chown -R ${RUN_USER}:${BACKUP_GROUP} ${BACKUP_REPO}
ExecStartPost=/bin/chmod -R g+rwX ${BACKUP_REPO}
EOF
)"

NEW_TIMER="$(cat <<EOF
# Generated by add_docker_volume_backup.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
[Unit]
Description=Run the encrypted Docker volume copy nightly at ${BACKUP_AT}

[Timer]
OnCalendar=${BACKUP_AT}
# A machine that was off catches up once rather than for every missed run
Persistent=true
# So a fleet of timers does not all start on the same second
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
)"

if [ "$DRY_RUN" -eq 1 ]; then
    print_header "Dry run: nothing was changed"
    [ -f "$BACKUP_REPO/config" ] \
        && print_status "  unchanged:    the repository at $BACKUP_REPO" \
        || print_status "  would create: $BACKUP_REPO"
    for pair in "$SERVICE_FILE|$NEW_SERVICE" "$TIMER_FILE|$NEW_TIMER"; do
        unit_path="${pair%%|*}"
        unit_body="${pair#*|}"
        if [ ! -f "$unit_path" ]; then
            print_status "  would write:  $unit_path"
        elif [ "$(cat "$unit_path")" = "$unit_body" ]; then
            print_status "  unchanged:    $unit_path"
        else
            print_status "  would update: $unit_path"
        fi
    done
    exit 0
fi

# =============================================================================
# restic, the password, and the repository
# =============================================================================
if ! command -v restic >/dev/null 2>&1; then
    print_status "restic is not installed yet, installing it..."
    show_spinner_watch_only "Updating package lists" apt-get update -qq || true
    if ! show_spinner_watch_only "Installing restic" apt-get install -y -qq restic; then
        print_error "restic could not be installed, so nothing would be copied."
        exit 1
    fi
    print_success "Installed restic."
fi

PASSWORD_CREATED=0
# The vault's copy first: it is the one the existing backups were made with, and
# restore_logins.sh runs later in the install than this.
if [ ! -f "$PASSWORD_FILE" ] && [ -f "$SCRIPT_DIR/restore_logins.sh" ]; then
    bash "$SCRIPT_DIR/restore_logins.sh" --only docker-backup-password || true
fi
if [ ! -f "$PASSWORD_FILE" ]; then
    ( umask 077; openssl rand -base64 32 > "$PASSWORD_FILE" )
    chmod 0600 "$PASSWORD_FILE"
    PASSWORD_CREATED=1
    print_success "Generated a repository password: $PASSWORD_FILE"
fi

mkdir -p "$(dirname "$BACKUP_REPO")"

if [ -f "$BACKUP_REPO/config" ]; then
    print_success "Encrypted repository already initialised."
else
    if show_spinner_watch_only "Initialising the encrypted repository" \
        restic init --repo "$BACKUP_REPO" --password-file "$PASSWORD_FILE"; then
        print_success "Initialised $BACKUP_REPO"
    else
        print_error "restic init failed, so the volumes would not be backed up."
        print_action "Run it by hand to see why:"
        print_action "  sudo restic init --repo $BACKUP_REPO --password-file $PASSWORD_FILE"
        exit 1
    fi
fi

# Owned by the machine's account so the file server's SMB pull, which lands as
# that user, can read it. The contents are encrypted, so this grants no reading
# of any volume to anything that can browse the share.
getent group "$BACKUP_GROUP" >/dev/null || groupadd --system "$BACKUP_GROUP"
chown "$RUN_USER:$RUN_USER" "$(dirname "$BACKUP_REPO")" 2>/dev/null || true
chown -R "$RUN_USER:$BACKUP_GROUP" "$BACKUP_REPO"
chmod -R g+rwX "$BACKUP_REPO"
chmod 2770 "$BACKUP_REPO"

UNITS_CHANGED=0
for pair in "$SERVICE_FILE|$NEW_SERVICE" "$TIMER_FILE|$NEW_TIMER"; do
    unit_path="${pair%%|*}"
    unit_body="${pair#*|}"
    if [ -f "$unit_path" ] && [ "$(cat "$unit_path")" = "$unit_body" ]; then
        continue
    fi
    printf '%s\n' "$unit_body" > "$unit_path"
    chmod 644 "$unit_path"
    UNITS_CHANGED=1
done

if [ "$UNITS_CHANGED" -eq 1 ]; then
    show_spinner_watch_only "Reloading systemd" systemctl daemon-reload
    print_success "Wrote $SERVICE_FILE and $TIMER_FILE: nightly at $BACKUP_AT."
else
    print_success "The units were already correct."
fi

# Not swallowed: an enable that fails leaves a machine whose only backup is the
# one this script runs below, which prints green and never happens again.
if ! enable_log="$(systemctl enable docker-volume-backup.timer 2>&1)"; then
    print_error "Could not enable docker-volume-backup.timer, so nothing will run nightly."
    printf '%s\n' "$enable_log"
    print_action "Check: systemctl status docker-volume-backup.timer"
fi
if ! systemctl is-active --quiet docker-volume-backup.timer; then
    if ! start_log="$(systemctl start docker-volume-backup.timer 2>&1)"; then
        print_error "Could not start docker-volume-backup.timer."
        printf '%s\n' "$start_log"
        print_action "Check: systemctl status docker-volume-backup.timer"
    fi
fi
if systemctl is-active --quiet docker-volume-backup.timer; then
    print_success "Timer armed. Next: $(systemctl list-timers docker-volume-backup.timer --no-pager 2>/dev/null | sed -n '2s/ \+/ /gp' | cut -d' ' -f1-4)"
fi

# Prove the backup works now, rather than discovering at the first real failure
# that it never ran.
if show_spinner_watch_only "Running the first backup" systemctl start docker-volume-backup.service; then
    print_success "First encrypted copy completed."
else
    print_error "The first copy failed, so the volumes are NOT leaving this machine."
    print_action "Logs: sudo journalctl -u docker-volume-backup.service -n 30 --no-pager"
fi

print_header "Done"
print_info "Snapshots:  sudo restic -r $BACKUP_REPO --password-file $PASSWORD_FILE snapshots"
print_info "Next run:   systemctl list-timers docker-volume-backup.timer"
if [ "$PASSWORD_CREATED" -eq 1 ]; then
    echo ""
    print_action "PUT THIS PASSWORD IN A VAULT. It is the only way to read the backup:"
    print_action "  $(cat "$PASSWORD_FILE")"
    print_info "It is shown once. The copy in $PASSWORD_FILE dies with this machine."
fi
