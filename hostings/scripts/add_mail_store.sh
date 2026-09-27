#!/usr/bin/env bash
# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it: seventeen units
# printed one line of text and sixteen empty ones. Silent there instead, since
# each of these loops already prints a summary when it finishes.
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
# The mail store, and the encrypted copy that leaves this machine.
#
# Runs before Postfix and Dovecot: both need the tree and the owning account to
# exist before they will start, and neither should be the thing that creates
# them.
#
# Two locations, and the split is the whole point of this script.
#
#   MAIL_ROOT          plaintext maildirs, 0700, owned by vmail, NOT shared.
#   MAIL_BACKUP_REPO   an encrypted restic repository under backup_files, which
#                      a file server on the LAN already copies off the machine.
#
# The maildirs are deliberately not put under backup_files directly. That share
# is `guest ok = yes`, so anything on the LAN could read every message. A restic
# repository is safe there because it is encrypted before it is written.
#
# The repository password is printed ONCE, on the run that creates it, and must
# go into a password vault. The copy on this machine dies with the machine.
#
# Safe to re-run: existing mailboxes, the repository and the timer are left
# alone. Re-run it after adding a mailbox row.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    redraw '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. An
# apt transaction or a restic write killed halfway is worse than a slow one.
show_spinner_watch_only() {
    local message="$1"
    shift
    # No terminal, no redraw: run it directly rather than spinning silently.
    if [ ! -t 1 ]; then "$@"; return $?; fi

    # Output goes to a log, not to the terminal. Both writing at once produced
    # apt's progress shredded through the spinner's redraw, one line of each
    # interleaved, and neither readable.
    #
    # Captured rather than discarded: on failure the last twenty lines are the
    # only explanation anyone gets, and "exit 100" on its own is undebuggable
    # over SSH.
    local log
    log="$(mktemp)"

    if [ "${DEBUG_MODE:-0}" = "1" ]; then
        # In debug mode the real output IS what is wanted, so no spinner.
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

# A spinner for work done in THIS shell, rather than in a command we launched.
#
# The pre-flight reads config, asks dpkg what is installed and asks systemd what
# is running. None of it can be backgrounded, because it fills arrays this shell
# needs. So the spinner is backgrounded instead, and stopped when the work ends.
#
# Killing it is safe: the only thing being signalled is our own spinner.
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            redraw '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
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
    redraw '\r\033[K'
}

MODE="apply"
ARG_DOMAIN=""
ARG_MAIL_ROOT=""
ARG_BACKUP_REPO=""
ARG_BACKUP_INTERVAL=""
ARG_MAILBOXES=()

usage() {
    echo "Usage: $0 [--check] [--domain <domain>] [--mail-root <path>]" >&2
    echo "          [--backup-repo <path>] [--backup-interval <systemd time>]" >&2
    echo "          [--mailbox <name>]..." >&2
    echo "" >&2
    echo "Anything not given is taken from hostings.conf if there is one," >&2
    echo "and asked for if there is not." >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)           MODE="check"; shift ;;
        --domain)          ARG_DOMAIN="$2"; shift 2 ;;
        --mail-root)       ARG_MAIL_ROOT="$2"; shift 2 ;;
        --backup-repo)     ARG_BACKUP_REPO="$2"; shift 2 ;;
        --backup-interval) ARG_BACKUP_INTERVAL="$2"; shift 2 ;;
        --mailbox)         ARG_MAILBOXES+=("$2"); shift 2 ;;
        -h|--help)         usage ;;
        *) print_error "Unknown argument: $1"; usage ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 ${1:-}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

# Not having one is fine. Without a config file every value comes from an
# argument or a prompt, which is how this runs on a machine that has only this
# script copied to it.
if [ ! -f "$SITES_CONF" ]; then
    print_info "No config at $SITES_CONF, so values are taken from arguments or asked for."
fi

# Resolve the account the machine belongs to. The encrypted repository is owned
# by it so the file server's SMB pull, which lands as this user, can read it.
if [ -n "$APP_USER" ]; then
    RUN_USER="$APP_USER"
elif [ -f /etc/manageserver-installer-user ]; then
    RUN_USER="$(cat /etc/manageserver-installer-user)"
elif [ -n "$SUDO_USER" ]; then
    RUN_USER="$SUDO_USER"
else
    RUN_USER="$(logname 2>/dev/null || whoami)"
fi

if ! id "$RUN_USER" >/dev/null 2>&1; then
    print_error "Resolved user '$RUN_USER' does not exist on this machine."
    print_action "Set it explicitly with: sudo env APP_USER=<name> $0"
    exit 1
fi

# -----------------------------------------------------------------------------
# hostings.conf settings reader, duplicated verbatim rather than sourced so this
# script stays runnable on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
declare -A _CONF_CACHE=()
conf_get() {
    local key="$1" default="$2" value
    if [ -n "${_CONF_CACHE[$key]+set}" ]; then
        value="${_CONF_CACHE[$key]}"
    else
        value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # tr -d '\r': xargs does not strip a carriage return, and a value is
        # the last thing on its line, so a CRLF config leaves one in it.
        value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
        _CONF_CACHE[$key]="$value"
    fi
    echo "${value:-$default}"
}

# --- Where values come from ---------------------------------------------------
#
# An argument, then the config file if there is one, then a prompt. That order
# is what lets one script serve two callers: an orchestrator passes arguments and
# it runs unattended, and somebody on a fresh machine with no config file answers
# a few questions instead.
#
# Prompts read /dev/tty, never stdin: a caller that redirected its own input
# would otherwise answer a later question with whatever it had buffered.
ask() {
    local prompt="$1" default="$2" answer
    if [ -n "$default" ]; then
        printf "\033[34m🔧 %s [%s]: \033[0m" "$prompt" "$default" > /dev/tty
    else
        printf "\033[34m🔧 %s: \033[0m" "$prompt" > /dev/tty
    fi
    read -r answer < /dev/tty
    printf '%s' "${answer:-$default}"
}

# resolve <value so far> <config key> <default> <prompt>
# Only asks when there is no sensible default. A prompt whose answer is
# "whatever you suggested" is a question that should not have been asked: it
# stops the run, makes the reader think they are deciding something, and the
# right answer was already on the screen.
#
# So resolve() prompts, and resolve_quiet() does not. Anything with a good
# default uses the quiet one.
resolve_quiet() {
    local current="$1" key="$2" default="$3" v
    [ -n "$current" ] && { printf %s "$current"; return 0; }
    if [ -f "$SITES_CONF" ]; then
        v="$(conf_get "$key" "")"
        [ -n "$v" ] && { printf %s "$v"; return 0; }
    fi
    printf %s "$default"
}

resolve() {
    local current="$1" key="$2" default="$3" prompt="$4" v
    [ -n "$current" ] && { printf '%s' "$current"; return 0; }
    if [ -f "$SITES_CONF" ]; then
        v="$(conf_get "$key" "")"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    ask "$prompt" "$default"
}

BASE_DOMAIN="$(resolve "$ARG_DOMAIN" BASE_DOMAIN "" "Your mail domain: the part after the @ in an address (the 'domain'), for example example.com")"
MAIL_ROOT="$(resolve_quiet "$ARG_MAIL_ROOT" MAIL_ROOT "/srv/mail")"
BACKUP_REPO="$(resolve_quiet "$ARG_BACKUP_REPO" MAIL_BACKUP_REPO "${MAIL_ROOT%/}_backup")"
# The group the SMB guest account reads and restores through, so the share
# never has to act as the machine's own account.
BACKUP_GROUP="$(conf_get BACKUP_READ_GROUP "$RUN_USER")"

# Backed up with the mail although it does not live with it: a signing key is
# the one part of a mail server that cannot be regenerated without republishing
# DNS and waiting for it to propagate.
DKIM_DIR="$(resolve_quiet "" MAIL_DKIM_DIR "/var/lib/rspamd/dkim")"
BACKUP_INTERVAL="$(resolve_quiet "$ARG_BACKUP_INTERVAL" MAIL_BACKUP_INTERVAL "15min")"
# Never prompted for: nobody chooses where a generated secret is written, and a
# default that is always the same is one less thing to get wrong.
PASSWORD_FILE="/root/.mail_backup_password"
if [ -f "$SITES_CONF" ]; then
    PASSWORD_FILE="$(conf_get MAIL_BACKUP_PASSWORD_FILE /root/.mail_backup_password)"
fi

VMAIL_USER="vmail"
VMAIL_UID=5000

print_header "Mail store"
print_status "Config:      $SITES_CONF"
print_status "Maildirs:    $MAIL_ROOT"
print_status "Encrypted:   $BACKUP_REPO"
print_status "Every:       $BACKUP_INTERVAL"

# Said before the first slow step rather than after it. The gap between the
# header and the restic install is where this looks stopped.
spinner_start "Checking the config"

# -----------------------------------------------------------------------------
# Pre-flight. Nothing is written until every mailbox row is known to be usable:
# a half-created mail tree is harder to reason about than a refusal.
# -----------------------------------------------------------------------------
ERRORS=()
WARNINGS=()

[ -z "$BASE_DOMAIN" ]     && ERRORS+=("BASE_DOMAIN is not set in $SITES_CONF")
[ -z "$MAIL_ROOT" ]       && ERRORS+=("MAIL_ROOT is not set in $SITES_CONF")
[ -z "$BACKUP_REPO" ]     && ERRORS+=("MAIL_BACKUP_REPO is not set in $SITES_CONF")

case "$MAIL_ROOT" in
    */backup_files|*/backup_files/*)
        ERRORS+=("MAIL_ROOT is under backup_files, which is a guest-readable SMB share.")
        ERRORS+=("  Plaintext mail must not live there. Only the encrypted repository may.")
        ;;
esac

# vmail delivers the mail, so it must be able to walk from / down to MAIL_ROOT.
# A parent it cannot enter (a 0750 home is the classic one) makes every delivery
# defer with an opaque "Internal error occurred", which costs an evening to
# diagnose after the fact. It cost one on 2026-08-26. Caught here now, before a
# single maildir is created, and named at the exact directory that blocks.
if [ -n "$MAIL_ROOT" ]; then
    _probe="$MAIL_ROOT"
    while [ ! -d "$_probe" ] && [ "$_probe" != "/" ]; do _probe="$(dirname "$_probe")"; done
    _chain=()
    _d="$_probe"
    while :; do
        _chain=("$_d" "${_chain[@]}")
        [ "$_d" = "/" ] && break
        _d="$(dirname "$_d")"
    done
    _blocker=""
    for _d in "${_chain[@]}"; do
        if id "$VMAIL_USER" >/dev/null 2>&1; then
            runuser -u "$VMAIL_USER" -- test -x "$_d" 2>/dev/null || { _blocker="$_d"; break; }
        else
            # vmail is created later in this script, so on a first run fall back to
            # the mode: an ancestor without world-execute that vmail will not own
            # blocks it. Odd last octal digit (1,3,5,7) means other has execute.
            case "$(stat -c %a "$_d")" in
                *[1357]) : ;;
                *) [ "$(stat -c %U "$_d")" != "$VMAIL_USER" ] && { _blocker="$_d"; break; } ;;
            esac
        fi
    done
    if [ -n "$_blocker" ]; then
        ERRORS+=("vmail cannot enter $_blocker, so mail delivered to $MAIL_ROOT would defer for good.")
        ERRORS+=("  Put the mail root where vmail can reach it, e.g. /srv/mail, not under a 0750 home.")
    fi
fi

MAILBOXES=()
SEEN=" "

# Given as arguments, the config file is not consulted for them at all. Mixing
# the two would mean a caller that passed three mailboxes silently got five.
if [ ${#ARG_MAILBOXES[@]} -gt 0 ]; then
    for _m in "${ARG_MAILBOXES[@]}"; do
        case "$_m" in
            *@*) MAILBOXES+=("${_m%@*}|${_m#*@}") ;;
            *)   MAILBOXES+=("${_m}|${BASE_DOMAIN}") ;;
        esac
    done
fi

while IFS='|' read -r type name port path subdomain rest; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "mailbox" ] && continue

    name="$(echo "$name" | xargs)"
    subdomain="$(echo "$subdomain" | xargs)"
    [ "$subdomain" = "-" ] || [ -z "$subdomain" ] && subdomain="$BASE_DOMAIN"

    if [ -z "$name" ]; then
        ERRORS+=("A mailbox row has no name, so there is no address to create")
        continue
    fi

    # Rejected here rather than by Postfix at delivery time, where the bounce is
    # the first anyone hears of it.
    if ! echo "$name" | grep -qE '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$'; then
        ERRORS+=("Mailbox name '$name' is not a usable local part (lowercase, digits, . _ -)")
        continue
    fi

    if echo "$SEEN" | grep -q " ${name}@${subdomain} "; then
        ERRORS+=("Mailbox ${name}@${subdomain} appears twice")
        continue
    fi
    SEEN="${SEEN}${name}@${subdomain} "

    MAILBOXES+=("${name}|${subdomain}")
done < <(if [ ${#ARG_MAILBOXES[@]} -eq 0 ] && [ -f "$SITES_CONF" ]; then grep -F '|' "$SITES_CONF" || true; fi)

[ ${#MAILBOXES[@]} -eq 0 ] && WARNINGS+=("No mailbox rows in $SITES_CONF, so only the store and the backup are set up")

# Every domain that has a mailbox gets contact@, whether a row asked for it or
# not. It is not an address like the others: it is the target every OTHER
# mailbox on that domain forwards to when it is removed, and manage_mail.sh
# refuses a delete outright when it has no maildir.
#
# So a domain whose contact row is missing has working mail right up until the
# first deletion, and then that deletion fails with a message about a mailbox
# nobody was thinking about. That happened on example.org on
# 2026-08-27: forwarding on the whole domain was broken and nothing had said so.
#
# Implicit, chosen by the owner on 2026-08-28 over refusing in check_config.sh. The
# argument against, recorded because it is real: this creates an address no row
# asked for, so the console will not show it and the config is no longer the
# whole truth about what exists. The argument for it won: the machine gets
# reflashed, and a rule the operator must remember is a rule that gets missed.
CONTACT_ADDED=()
for _domain in $(printf '%s\n' ${MAILBOXES+"${MAILBOXES[@]}"} | cut -d'|' -f2 | sort -u); do
    [ -n "$_domain" ] || continue
    printf '%s\n' ${MAILBOXES+"${MAILBOXES[@]}"} | grep -qx "contact|${_domain}" && continue
    MAILBOXES+=("contact|${_domain}")
    CONTACT_ADDED+=("contact@${_domain}")
done
if [ ${#CONTACT_ADDED[@]} -gt 0 ]; then
    WARNINGS+=("Adding ${CONTACT_ADDED[*]}: every domain with mail needs a contact@ for removals to forward to, and no row asked for it")
fi

spinner_stop
if ! command -v restic >/dev/null 2>&1; then
    print_status "restic is not installed yet, installing it..."
    # Lists first. On a machine that has not seen apt in a while the install
    # fails on a 404 for a package version that no longer exists, which reads as
    # "restic is unavailable" rather than "the lists are stale".
    show_spinner_watch_only "Updating package lists" apt-get update -qq || true
    if ! show_spinner_watch_only "Installing restic" apt-get install -y -qq restic; then
        ERRORS+=("restic could not be installed, so the encrypted backup cannot be set up")
    fi
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
    for w in "${WARNINGS[@]}"; do print_info "$w"; done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

spinner_stop
print_success "Pre-flight passed: ${#MAILBOXES[@]} mailbox(es)."

# --check stops here. Everything above is reading and validating; everything
# below creates a user, writes maildirs and initialises a repository. The line
# between the two is exactly where a check run should end.
if [ "$MODE" = "check" ]; then
    for mb in "${MAILBOXES[@]}"; do
        name="${mb%%|*}"; dom="${mb##*|}"
        if [ -d "$MAIL_ROOT/$dom/$name" ]; then
            print_success "  ${name}@${dom} already has a maildir"
        else
            print_status "  would create a maildir for ${name}@${dom}"
        fi
    done
    id "$VMAIL_USER" >/dev/null 2>&1 \
        && print_success "  the $VMAIL_USER user exists" \
        || print_status "  would create the $VMAIL_USER user"
    [ -f "$BACKUP_REPO/config" ] \
        && print_success "  the encrypted repository exists" \
        || print_status "  would initialise $BACKUP_REPO"
    print_status "--check, so nothing was written."
    exit 0
fi

# -----------------------------------------------------------------------------
# The owning account. One system user owns every maildir, which is what lets
# Dovecot deliver without a login account existing per address.
# -----------------------------------------------------------------------------
if ! getent group "$VMAIL_USER" >/dev/null 2>&1; then
    groupadd -g "$VMAIL_UID" "$VMAIL_USER"
    print_success "Created group $VMAIL_USER ($VMAIL_UID)."
fi

if ! id "$VMAIL_USER" >/dev/null 2>&1; then
    useradd -r -u "$VMAIL_UID" -g "$VMAIL_USER" -d "$MAIL_ROOT" \
        -s /usr/sbin/nologin -c "Virtual mail owner" "$VMAIL_USER"
    print_success "Created user $VMAIL_USER ($VMAIL_UID), no shell."
fi

# -----------------------------------------------------------------------------
# The tree. Maildir format, one file per message: a copy taken mid-delivery
# loses at most the message being written, where a single-file format would
# lose the folder.
# -----------------------------------------------------------------------------
CREATED=()
EXISTING=()

mkdir -p "$MAIL_ROOT"
chown "$VMAIL_USER:$VMAIL_USER" "$MAIL_ROOT"
chmod 0700 "$MAIL_ROOT"

# The DKIM signing keys are NOT here, and that is deliberate. This directory is
# 0700 vmail and rspamd cannot traverse it, so a key kept here could never be
# read by the one process that needs it. add_rspamd.sh puts them in its own
# directory instead; the restic unit below backs that up alongside the mail, so
# the key still travels with a restore.

for entry in ${MAILBOXES+"${MAILBOXES[@]}"}; do
    IFS='|' read -r mb_name mb_domain <<< "$entry"
    mb_dir="$MAIL_ROOT/$mb_domain/$mb_name"

    if [ -d "$mb_dir" ]; then
        EXISTING+=("${mb_name}@${mb_domain}")
    else
        CREATED+=("${mb_name}@${mb_domain}")
    fi

    mkdir -p "$mb_dir"/{cur,new,tmp}
    chown -R "$VMAIL_USER:$VMAIL_USER" "$MAIL_ROOT/$mb_domain"
    # X, not x: directories need traversal, message files do not need to be
    # executable and -R 0700 would make every one of them so.
    chmod -R u=rwX,go= "$MAIL_ROOT/$mb_domain"
done

# -----------------------------------------------------------------------------
# The encrypted copy.
#
# restic rather than a nightly tar: it writes only what changed, so a fifteen
# minute interval costs almost nothing on a run with no new mail, where a full
# archive would rewrite the whole store every time and defeat the file server's
# own incremental copy.
# -----------------------------------------------------------------------------
PASSWORD_CREATED=0
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
        print_error "restic init failed, so mail would not be backed up."
        print_action "Run it by hand to see why:"
        print_action "  sudo restic init --repo $BACKUP_REPO --password-file $PASSWORD_FILE"
        exit 1
    fi
fi

# Owned by the machine's account so the file server's SMB pull, which lands as
# that user, can read it. The contents are encrypted, so this grants no reading
# of mail to anything that can browse the share.
getent group "$BACKUP_GROUP" >/dev/null || groupadd --system "$BACKUP_GROUP"
chown -R "$RUN_USER:$BACKUP_GROUP" "$BACKUP_REPO"
chmod -R g+rwX "$BACKUP_REPO"
chmod 2770 "$BACKUP_REPO"

# -----------------------------------------------------------------------------
# The timer.
#
# `forget` runs in the same unit, without --prune. Ninety-six snapshots a day
# would otherwise accumulate for ever; dropping the metadata is cheap, and
# reclaiming the space is not, so pruning is left as a deliberate manual step.
# -----------------------------------------------------------------------------
SERVICE_FILE="/etc/systemd/system/mail-backup.service"
TIMER_FILE="/etc/systemd/system/mail-backup.timer"

NEW_SERVICE="$(cat <<EOF
# Generated by add_mail_store.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
[Unit]
Description=Encrypted off-machine copy of the mail store
After=network.target

[Service]
Type=oneshot
Environment=RESTIC_PASSWORD_FILE=${PASSWORD_FILE}
Environment=RESTIC_REPOSITORY=${BACKUP_REPO}
ExecStart=/usr/bin/restic backup --quiet --tag mail ${MAIL_ROOT} ${DKIM_DIR}
ExecStart=/usr/bin/restic forget --quiet --tag mail \\
    --keep-last 96 --keep-daily 7 --keep-weekly 4 --keep-monthly 12
# root writes the new pack files; without this the SMB pull never sees them.
ExecStartPost=/bin/chown -R ${RUN_USER}:${BACKUP_GROUP} ${BACKUP_REPO}
ExecStartPost=/bin/chmod -R g+rwX ${BACKUP_REPO}
EOF
)"

NEW_TIMER="$(cat <<EOF
# Generated by add_mail_store.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
[Unit]
Description=Run the encrypted mail copy every ${BACKUP_INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${BACKUP_INTERVAL}
# A machine that was off catches up once rather than for every missed run
Persistent=true

[Install]
WantedBy=timers.target
EOF
)"

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
    print_success "Backup timer written."
fi

systemctl enable mail-backup.timer >/dev/null 2>&1 || true
if ! systemctl is-active --quiet mail-backup.timer; then
    systemctl start mail-backup.timer >/dev/null 2>&1 || true
fi

# Prove the backup works now, rather than discovering at the first real failure
# that it never ran. A first run on an empty store takes a second.
if show_spinner_watch_only "Running the first backup" systemctl start mail-backup.service; then
    print_success "First encrypted backup completed."
else
    print_error "The first backup failed, so mail is NOT being copied off this machine."
    print_action "Logs: sudo journalctl -u mail-backup.service -n 30 --no-pager"
fi

# -----------------------------------------------------------------------------
# What changed
# -----------------------------------------------------------------------------
echo ""
[ ${#CREATED[@]} -gt 0 ]  && print_success "Created:  ${CREATED[*]}"
[ ${#EXISTING[@]} -gt 0 ] && print_success "Existing: ${EXISTING[*]}"

print_status "Next: add_dovecot.sh sets the passwords for these mailboxes."

if [ "$PASSWORD_CREATED" -eq 1 ]; then
    echo ""
    print_action "================================================================"
    print_action " PUT THIS IN YOUR PASSWORD VAULT NOW. IT IS SHOWN ONCE."
    print_action "================================================================"
    print_info " Without it the encrypted backup cannot be read by anyone,"
    print_info " including you. The copy in $PASSWORD_FILE"
    print_info " dies with this machine, which is the case it exists for."
    echo ""
    printf "   \033[36mrestic repository: %s\033[0m\n" "$BACKUP_REPO"
    printf "   \033[36mpassword:          %s\033[0m\n" "$(cat "$PASSWORD_FILE")"
    echo ""
    print_action " Restore with:"
    print_action "   restic -r <copy of the repo> restore latest --target /"
    print_action "================================================================"
fi

print_success "Mail store configured."
