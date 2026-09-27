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
# Roundcube: read this machine's mail in a browser.
#
# IT STORES NOTHING THAT MATTERS
#
# Roundcube keeps settings, contacts and drafts in a database. The MAIL itself
# stays in Dovecot's maildirs, which is what the backup covers. So this database
# is genuinely disposable: losing it costs an address book and some preferences,
# not a single message.
#
# SQLite rather than MySQL for exactly that reason. A whole database server for
# three mailboxes' worth of preferences is a service to patch, back up and
# restart for no gain, and a file is a file: the "restore by copying" story that
# decided Maildir and passwd-file accounts applies here too.
#
# NO SEPARATE LOGIN
#
# It authenticates against Dovecot over IMAP, so the accounts are the same ones
# add_dovecot.sh created. There is no Roundcube account list to keep in step.
#
# Usage:
#   sudo bash add_roundcube.sh            install and configure
#   sudo bash add_roundcube.sh --check    report what would change
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

# --- Busy indicator -----------------------------------------------------------
#
# Duplicated into every script here rather than sourced, which is this repo's
# rule: any one of these can be copied to a machine on its own and still run.
#
# Watch-only: it shows the command is alive and never signals it. An apt
# transaction killed halfway is worse than a slow one.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Output goes to a log, never to the terminal alongside the spinner: both
# writing at once shreds each other's lines. Captured rather than discarded,
# because "exit 100" with no output is undebuggable over SSH.
show_spinner_watch_only() {
    local message="$1"
    shift
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
    printf '\r\033[K'

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

MODE="apply"
ARG_DOMAIN=""
ARG_HOSTNAME=""

usage() {
    echo "Usage: $0 [--check] [--domain <domain>] [--hostname <mail.example.com>]" >&2
    echo "" >&2
    echo "Anything not given is taken from hostings.conf if there is one," >&2
    echo "and asked for if there is not." >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)    MODE="check"; shift ;;
        --domain)   ARG_DOMAIN="$2"; shift 2 ;;
        --hostname) ARG_HOSTNAME="$2"; shift 2 ;;
        -h|--help)  usage ;;
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

# Not having one is fine: every value then comes from an argument or a prompt.
if [ ! -f "$SITES_CONF" ]; then
    print_info "No config at $SITES_CONF, so values are taken from arguments or asked for."
fi

conf_get() {
    local key="$1" default="${2:-}" value
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" \
             | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}

# An argument, then the config file if there is one, then a prompt.
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
    [ -n "$current" ] && { printf "%s" "$current"; return 0; }
    if [ -f "$SITES_CONF" ]; then
        v="$(conf_get "$key" "")"
        [ -n "$v" ] && { printf "%s" "$v"; return 0; }
    fi
    ask "$prompt" "$default"
}

BASE_DOMAIN="$(resolve "$ARG_DOMAIN" BASE_DOMAIN "" "Your mail domain: the part after the @ in an address (the 'domain'), for example example.com")"
MAIL_HOSTNAME="${ARG_HOSTNAME:-mail.${BASE_DOMAIN}}"
RC_DIR="/var/lib/roundcube"
RC_CONF="/etc/roundcube/config.inc.php"
PW_CONF="/etc/roundcube/plugins/password/config.inc.php"
CHPASSWD="/usr/local/sbin/mail_chpasswd.sh"
PW_SUDOERS="/etc/sudoers.d/021_roundcube-password"
DEBIAN_DB_INC="/etc/roundcube/debian-db.php"

# WHETHER TO VERIFY THE CERTIFICATE, decided here rather than left as a step on
# a checklist. Item 15 was that checklist entry: "set both verify_peer flags
# back to true at the drive swap", which is a thing a person has to remember on
# the day, and the flags fail OPEN if they forget.
#
# Both conditions, and neither is assumed:
#   - MACHINE_IS_LIVE = yes, because while it is no every certificate here comes
#     from Let's Encrypt's STAGING issuer and no client trusts one
#   - a certificate for $MAIL_HOSTNAME actually exists on disk, because it is
#     requested per MAILBOX row and a machine with none has no lineage at all
#
# When both hold, Roundcube dials the NAME rather than 127.0.0.1, and a hosts
# entry keeps that name on loopback. Dialling 127.0.0.1 and verifying is not a
# thing that can ever work: no certificate carries an IP address as its name.
# The hosts entry, not public DNS, because a public record points at the
# router's address and a connection out and back in usually does not survive it.
RC_LIVE=0
RC_VERIFY=0
case "$(conf_get MACHINE_IS_LIVE no | tr '[:upper:]' '[:lower:]')" in
    y|yes|true|1) RC_LIVE=1 ;;
esac
[ "$RC_LIVE" -eq 1 ] && [ -f "/etc/letsencrypt/live/${MAIL_HOSTNAME}/fullchain.pem" ] && RC_VERIFY=1
if [ "$RC_VERIFY" -eq 1 ]; then
    RC_IMAP_HOST="ssl://${MAIL_HOSTNAME}:993"
    RC_SMTP_HOST="tls://${MAIL_HOSTNAME}:587"
    RC_VERIFY_PHP="true"
else
    RC_IMAP_HOST="ssl://127.0.0.1:993"
    RC_SMTP_HOST="tls://127.0.0.1:587"
    RC_VERIFY_PHP="false"
fi

print_header "Roundcube"
print_status "Config:  $SITES_CONF"
print_status "IMAP:    $MAIL_HOSTNAME"
print_status "Mode:    $MODE"
spinner_start "Checking the config"

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()

[ -z "$BASE_DOMAIN" ] && ERRORS+=("No BASE_DOMAIN in $SITES_CONF")

if ! systemctl is-active --quiet dovecot 2>/dev/null; then
    ERRORS+=("Dovecot is not running, and this reads mail through it.")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_dovecot.sh")
fi

if ! id www-data >/dev/null 2>&1; then
    ERRORS+=("There is no www-data user, so Apache is not installed.")
fi

# THE CASE WORTH REFUSING IS A LIVE MACHINE THAT CANNOT VERIFY, which is the
# opposite of what this used to check. It demanded a $BASE_DOMAIN lineage that
# Roundcube never looks at, gave "IMAP is verified over TLS" as the reason when
# verify_peer had been false for a week, and refused outright on a machine with
# no mailbox rows.
#
# Silently falling back to unverified is fine while MACHINE_IS_LIVE is no. On a
# live machine it is the failure item 15 existed to prevent, so it stops here
# instead.
if [ "$RC_LIVE" -eq 1 ] && [ "$RC_VERIFY" -eq 0 ]; then
    ERRORS+=("MACHINE_IS_LIVE is yes but ${MAIL_HOSTNAME} has no certificate,")
    ERRORS+=("  so webmail could only run WITHOUT verifying who it talks to.")
    ERRORS+=("  Add a mailbox row for the domain, then: sudo bash $SCRIPT_DIR/add_site_certificates.sh")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    spinner_stop
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

spinner_stop
print_success "Pre-flight passed."

# =============================================================================
# Install
#
# Preseeded to SQLite, or the package opens a database dialogue and an
# unattended install stops on it.
# =============================================================================
# acl: Roundcube reaches its package-owned files through ACLs, see below.
PACKAGES=(roundcube-core roundcube-sqlite3 roundcube-plugins acl)
MISSING=()
for p in "${PACKAGES[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    if [ "$MODE" = "check" ]; then
        print_status "would install: ${MISSING[*]}"
    else
        print_status "Installing ${MISSING[*]}..."
        debconf-set-selections <<'EOF'
roundcube-core roundcube/dbconfig-install boolean true
roundcube-core roundcube/database-type select sqlite3
EOF
        show_spinner_watch_only "Updating package lists" apt-get update -qq || true
        if ! show_spinner_watch_only "Installing ${MISSING[*]}" \
             apt-get install -y -qq --no-install-recommends "${MISSING[@]}"; then
            exit 1
        fi
        print_success "Installed ${MISSING[*]}"
    fi
else
    print_success "Roundcube already installed."
fi

# Without this file there is no database, and the config below would point at
# nothing: fail here rather than at someone's first login.
if [ "$MODE" != "check" ] && [ ! -f "$DEBIAN_DB_INC" ]; then
    print_error "No $DEBIAN_DB_INC, so dbconfig-common never created the database."
    print_error "  Run: sudo dpkg-reconfigure roundcube-core   (choose sqlite3)"
    exit 1
fi

# =============================================================================
# Its own account and PHP pool, item 146
#
# As www-data it ran as the account Apache reads every site with, so a bug in
# it could read every customer's files and the console's password hashes.
#
# ACLs rather than chown for what the package owns: an upgrade puts those back
# to www-data, and a default ACL on the folder is inherited by the new file.
# =============================================================================
RC_USER="roundcube"
PHP_FPM_VER="$(ls -d /etc/php/*/fpm 2>/dev/null | sort -V | tail -1 | cut -d/ -f4)"
RC_POOL_FILE="/etc/php/${PHP_FPM_VER}/fpm/pool.d/${RC_USER}.conf"
RC_SOCKET="/run/php/${RC_USER}.sock"

if [ "$MODE" = "check" ]; then
    id "$RC_USER" >/dev/null 2>&1 || print_status "would create the account $RC_USER"
    [ -f "$RC_POOL_FILE" ] || print_status "would write $RC_POOL_FILE"
else
    if [ -z "$PHP_FPM_VER" ] || ! command -v setfacl >/dev/null 2>&1; then
        print_error "Roundcube runs in a PHP-FPM pool of its own, which needs php-fpm and setfacl (acl)."
        print_action "Install them: sudo apt-get install php-fpm acl"
        exit 1
    fi
    if ! id "$RC_USER" >/dev/null 2>&1; then
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$RC_USER"
        print_success "Created the account $RC_USER"
    fi

    setfacl -R -m "u:${RC_USER}:rX" -m "d:u:${RC_USER}:rX" /etc/roundcube
    for d in /var/lib/dbconfig-common/sqlite3/roundcube /var/lib/roundcube/temp /var/log/roundcube; do
        [ -d "$d" ] && setfacl -R -m "u:${RC_USER}:rwX" -m "d:u:${RC_USER}:rwX" "$d"
    done
    # logrotate's new file gets 0640, which caps any ACL at read: it has to be ours.
    if [ -f /etc/logrotate.d/roundcube-core ]; then
        sed -i "s/^\([[:space:]]*create[[:space:]]\+[0-7]\+[[:space:]]\+\)www-data\([[:space:]]\)/\1${RC_USER}\2/" /etc/logrotate.d/roundcube-core
    fi
    print_success "$RC_USER can read its config and write its database, temp and logs."

    RC_POOL="$(cat <<EOF
; Generated by add_roundcube.sh, rewritten on every run.
; Roundcube, and nothing else, runs in this pool.
[${RC_USER}]
user = ${RC_USER}
group = ${RC_USER}
listen = ${RC_SOCKET}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 60s
EOF
)"
    if [ ! -f "$RC_POOL_FILE" ] || [ "$(cat "$RC_POOL_FILE")" != "$RC_POOL" ]; then
        printf '%s\n' "$RC_POOL" > "$RC_POOL_FILE"
        if ! "php-fpm${PHP_FPM_VER}" -t >/dev/null 2>&1; then
            print_error "PHP-FPM rejected $RC_POOL_FILE, so it was removed again:"
            "php-fpm${PHP_FPM_VER}" -t 2>&1 | tail -5
            rm -f "$RC_POOL_FILE"
            exit 1
        fi
        systemctl reload "php${PHP_FPM_VER}-fpm"
        print_success "Wrote $RC_POOL_FILE: Roundcube runs as $RC_USER."
    fi
fi

# =============================================================================
# Configuration
#
# des_key is generated once and kept. It encrypts the IMAP password held in the
# session, so changing it logs everyone out; that is harmless but pointless, and
# a value regenerated on every run would do it on every run.
# =============================================================================
DES_KEY_FILE="/etc/roundcube/des_key"
if [ "$MODE" != "check" ] && [ ! -f "$DES_KEY_FILE" ]; then
    install -m 0640 -o root -g "$RC_USER" /dev/null "$DES_KEY_FILE"
    openssl rand -base64 24 | tr -d '\n' > "$DES_KEY_FILE"
    print_success "Generated $DES_KEY_FILE"
fi
[ "$MODE" != "check" ] && chgrp "$RC_USER" "$DES_KEY_FILE" && chmod 0640 "$DES_KEY_FILE"
DES_KEY="$(cat "$DES_KEY_FILE" 2>/dev/null || echo 'placeholder-not-yet-generated')"

RC_CONTENT="$(cat <<EOF
<?php
// Generated by add_roundcube.sh from /etc/hostings/hostings.conf
// Do not edit by hand: the next run overwrites it. Edit the config instead.

// Settings and contacts only. Every message lives in Dovecot's maildirs, which
// is what the backup covers, so this file is disposable by design.
//
// dbconfig-common creates this database and migrates its schema when
// roundcube-core is upgraded, so its path is read from the file dbconfig
// maintains rather than written here, where a moved path would go unnoticed.
require_once('${DEBIAN_DB_INC}');
if (\$dbtype !== 'sqlite3') {
    die('Expected the sqlite3 database dbconfig-common was preseeded to create, got: ' . \$dbtype);
}
\$config['db_dsnw'] = 'sqlite:///' . \$basepath . '/' . \$dbname . '?mode=0640';

// Over TLS to this machine's own Dovecot, always on loopback. Whether the
// certificate is VERIFIED is decided by the machine, not by a person
// remembering: verify_peer here is ${RC_VERIFY_PHP}.
//
// Verified when MACHINE_IS_LIVE = yes AND a certificate for ${MAIL_HOSTNAME}
// exists. Then this dials the NAME, and a 127.0.0.1 line in /etc/hosts keeps
// the connection on loopback while the name still matches the certificate.
//
// Unverified otherwise, and both reasons are real rather than cautious:
//   - while MACHINE_IS_LIVE is no, every certificate here comes from Let's
//     Encrypt's STAGING issuer, which no client trusts
//   - the mail lineage is requested per MAILBOX row, so a machine with no
//     mailboxes has no certificate to verify against at all
//
// WHAT UNVERIFIED EXPOSES. Roundcube does not check who it is talking to on
// this connection. It is 127.0.0.1 to 127.0.0.1 and never touches a network,
// so there is no position for anything to sit in the middle of it. Anyone who
// could intercept loopback here already has root on this machine.
//
// Verifying against 127.0.0.1 is not an option that was skipped: no
// certificate carries an IP address as its name, so it could never pass.
\$config['imap_host'] = '${RC_IMAP_HOST}';
\$config['imap_conn_options'] = array(
    'ssl' => array('verify_peer' => ${RC_VERIFY_PHP}, 'verify_peer_name' => ${RC_VERIFY_PHP}),
);

// Sending goes through Postfix on this machine, authenticated as the person
// who is logged in, so Postfix's "you may only send as yourself" rule applies
// to webmail exactly as it does to a mail client.
//
// Loopback and the same TLS decision: submission on 587 presents the same
// certificate for the same name, so it is verified on exactly the same terms.
\$config['smtp_host'] = '${RC_SMTP_HOST}';
\$config['smtp_conn_options'] = array(
    'ssl' => array('verify_peer' => ${RC_VERIFY_PHP}, 'verify_peer_name' => ${RC_VERIFY_PHP}),
);
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';

\$config['support_url'] = '';
\$config['product_name'] = 'Mail';
\$config['des_key'] = '${DES_KEY}';
// password lets the owner of a mailbox change their own password, which is the
// other half of the console setting a default one. Its own settings live in
// /etc/roundcube/plugins/password/config.inc.php, written below.
\$config['plugins'] = array('archive', 'zipdownload', 'managesieve', 'password');

\$config['skin'] = 'elastic';
\$config['login_lc'] = 2;

// The login is the full address, because two domains can each have an 'info'
// and a bare username would be ambiguous.
\$config['username_domain'] = '';
\$config['mail_domain'] = '';

// A session that never expires is an unlocked mailbox on a shared screen.
\$config['session_lifetime'] = 30;
EOF
)"

if [ "$MODE" = "check" ]; then
    # Compared rather than assumed, same reason as everywhere else here: a check
    # that always claims a change is a check nobody reads.
    TMP="$(mktemp)"
    printf '%s\n' "$RC_CONTENT" > "$TMP"
    if [ ! -f "$RC_CONF" ] || ! cmp -s "$TMP" "$RC_CONF"; then
        print_status "would write $RC_CONF"
    else
        print_success "$RC_CONF already correct"
    fi
    rm -f "$TMP"
    [ -f "$PW_CONF" ]  || print_status "would write $PW_CONF"
    [ -x "$CHPASSWD" ] || print_status "would install $CHPASSWD"
    print_status "would grant $RC_USER $CHPASSWD"
    print_status "--check, so nothing was written."
    exit 0
fi

TMP="$(mktemp)"
printf '%s\n' "$RC_CONTENT" > "$TMP"
if [ ! -f "$RC_CONF" ] || ! cmp -s "$TMP" "$RC_CONF"; then
    install -m 0640 -o root -g "$RC_USER" "$TMP" "$RC_CONF"
    print_success "Wrote $RC_CONF"
fi
rm -f "$TMP"

# THE NAME, PINNED TO LOOPBACK. Only when verifying, because only then does
# Roundcube dial the name at all.
#
# Without this the lookup goes to public DNS, which after the swap answers with
# the router's address, and a connection from behind the router out to its own
# public address and back in is a hairpin that most home routers drop. The mail
# stack is on this machine, so the honest answer to "where is mail.<domain>" here
# is 127.0.0.1.
#
# Removed again when not verifying, so a machine that goes back to staging does
# not keep a stale override nothing reads.
HOSTS_MARK="# ${MAIL_HOSTNAME} on loopback, written by add_roundcube.sh"
if [ "$MODE" != "check" ]; then
    if grep -qF "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
        sed -i "\|$HOSTS_MARK|d; \|^127\.0\.0\.1[[:space:]]\+${MAIL_HOSTNAME}\$|d" /etc/hosts
    fi
    if [ "$RC_VERIFY" -eq 1 ]; then
        printf '%s\n127.0.0.1 %s\n' "$HOSTS_MARK" "$MAIL_HOSTNAME" >> /etc/hosts
        print_success "$MAIL_HOSTNAME resolves to 127.0.0.1, so the verified name stays on loopback."
    fi
fi

if [ "$RC_VERIFY" -eq 1 ]; then
    print_success "Webmail verifies Dovecot's certificate: MACHINE_IS_LIVE is yes and $MAIL_HOSTNAME has one."
else
    print_info "Webmail does NOT verify Dovecot's certificate, on loopback only."
    print_info "  It turns itself on when MACHINE_IS_LIVE = yes and $MAIL_HOSTNAME has a certificate."
fi

# =============================================================================
# The password plugin
#
# The driver is our own, `checked_chpasswd`: it writes the address, the CURRENT
# password and the new one to mail_chpasswd.sh's stdin, and that script checks
# the current one against Dovecot's file before set_mail_password.sh changes
# anything. Item 146: the stock driver sent only the new password, so the only
# check was inside Roundcube, and a bug in it could set any mailbox's password.
#
# THE GRANT IS ONE LITERAL COMMAND, no wildcard, because everything arrives on
# stdin rather than as an argument. What it may do is bounded by the scripts it
# calls: a wrong current password is refused, an address with no maildir is
# refused, dkim is refused, and a password under eight characters is refused.
# =============================================================================
RC_DRIVER_SRC="$SCRIPT_DIR/roundcube_password_driver.php"
RC_DRIVER="/usr/share/roundcube/plugins/password/drivers/checked_chpasswd.php"
if [ ! -f "$SCRIPT_DIR/mail_chpasswd.sh" ] || [ ! -f "$RC_DRIVER_SRC" ]; then
    print_warning "mail_chpasswd.sh or its Roundcube driver is missing, so nobody can change their own password."
else
    install -m 0700 -o root -g root "$SCRIPT_DIR/mail_chpasswd.sh" "$CHPASSWD"
    install -m 0644 -o root -g root "$RC_DRIVER_SRC" "$RC_DRIVER"
    print_success "Installed $CHPASSWD and the driver that sends it the current password"
fi

mkdir -p "$(dirname "$PW_CONF")"
PW_CONTENT="$(cat <<EOF
<?php
// Written by add_roundcube.sh. Edit the script, not this file.

// The console sets a default password; this is how the owner replaces it.
\$config['password_driver'] = 'checked_chpasswd';
\$config['password_chpasswd_cmd'] = 'sudo ${CHPASSWD}';

// The session's current password is re-checked before anything is written, so
// a walked-up-to screen cannot lock the owner out of their own mailbox.
\$config['password_confirm_current'] = true;

// The same floor set_mail_password.sh enforces, said in both places so the user
// is told before the request is made rather than after it is refused.
\$config['password_minimum_length'] = 8;

// This machine hosts one Dovecot for every domain it serves, and every account
// in it may change its own password.
\$config['password_login_exceptions'] = null;
EOF
)"

TMP="$(mktemp)"
printf '%s\n' "$PW_CONTENT" > "$TMP"
if [ ! -f "$PW_CONF" ] || ! cmp -s "$TMP" "$PW_CONF"; then
    install -m 0640 -o root -g "$RC_USER" "$TMP" "$PW_CONF"
    print_success "Wrote $PW_CONF"
fi
rm -f "$TMP"

TMP_SUDOERS="$(mktemp)"
{
    echo "# Written by add_roundcube.sh. Roundcube's password plugin, and nothing else."
    echo "# The address and the password both arrive on stdin, so there is no argument"
    echo "# list to smuggle anything into."
    echo "${RC_USER} ALL=(root) NOPASSWD: ${CHPASSWD}"
} > "$TMP_SUDOERS"

if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    print_error "The generated sudoers file is invalid, so nothing was installed."
    rm -f "$TMP_SUDOERS"
    exit 1
fi
install -m 0440 -o root -g root "$TMP_SUDOERS" "$PW_SUDOERS"
rm -f "$TMP_SUDOERS"
print_success "Granted ${RC_USER} ${CHPASSWD}, and nothing else. www-data holds no grant."

# The temp and log directories belong to Roundcube, and nothing else on the machine
# has any reason to read them. The database is dbconfig-common's to own.
for d in /var/lib/roundcube/temp /var/log/roundcube; do
    [ -d "$d" ] && chown -R "$RC_USER:$RC_USER" "$d"
done

# Debian ships an Apache snippet that publishes Roundcube at /roundcube on every
# vhost, including customers' sites. Disabled: this repo decides what each
# hostname serves, and a webmail login appearing under a customer's domain is
# not something a package gets to decide.
if [ -e /etc/apache2/conf-enabled/roundcube.conf ]; then
    a2disconf roundcube >/dev/null 2>&1 || true
    print_success "Disabled Debian's site-wide /roundcube alias."
    systemctl reload apache2 2>/dev/null || true
fi

echo ""
print_success "Roundcube installed. Nothing serves it yet, by design."
print_status "Give it a hostname by adding a row to hostings.conf:"
print_status "  website | webmail | - | ../../../usr/share/roundcube | webmail | - | - | no | - | - | live | -"
print_status "Then: sudo bash $SCRIPT_DIR/maintain_services.sh --apply"
echo ""
print_info "It logs in with the full address, for example admin@${BASE_DOMAIN},"
print_info "and the password add_dovecot.sh asked for."
