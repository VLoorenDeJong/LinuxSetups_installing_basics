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
# Dovecot: the mailboxes, and the two doors into them.
#
# add_mail_store.sh made the store. This makes it usable:
#
#   IMAPS on 993     a mail client reads and writes here
#   LMTP on a socket Postfix hands delivered mail over, and Dovecot files it
#   auth socket      Postfix asks Dovecot whether a sender may send
#
# ACCOUNTS ARE A PASSWD FILE, NOT SYSTEM USERS
#
# One file of hashes, owned by root, listing every mailbox in hostings.conf. It
# was chosen on one question: what makes the backup a set of files you can copy?
# A database needs a dump taken and restored in step, and system users need
# /etc/shadow merged into a fresh machine. Neither is a copy.
#
# So a rebuilt machine restores mail by copying MAIL_ROOT back and running this
# script. Nothing else.
#
# PASSWORDS ARE ASKED FOR, NEVER GENERATED HERE
#
# A password this script invents has to be shown, and anything shown ends up in
# a terminal log or a screenshot. It prompts for each new mailbox instead and
# leaves existing ones alone, so a re-run is safe.
#
# Usage:
#   sudo bash add_dovecot.sh              install, configure, add missing accounts
#   sudo bash add_dovecot.sh --check      report what it would do, change nothing
#   sudo bash add_dovecot.sh --passwd <name@domain>   set one password
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

usage() {
    echo "Usage: $0 [--check] [--passwd <name@domain>]" >&2
    echo "" >&2
    echo "  --check   report what would change, write nothing" >&2
    echo "  --passwd  set the password for one mailbox and stop" >&2
    exit 1
}

MODE="apply"
ONE_PASSWD=""
ARG_DOMAIN=""
ARG_MAIL_ROOT=""
ARG_CERT_DIR=""
ARG_MAILBOXES=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check)     MODE="check"; shift ;;
        --passwd)    ONE_PASSWD="$2"; shift 2 ;;
        --domain)    ARG_DOMAIN="$2"; shift 2 ;;
        --mail-root) ARG_MAIL_ROOT="$2"; shift 2 ;;
        --cert-dir)  ARG_CERT_DIR="$2"; shift 2 ;;
        --mailbox)   ARG_MAILBOXES+=("$2"); shift 2 ;;
        -h|--help)   usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
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

# An argument, then the config file if there is one, then a prompt. Same order
# in every script here, so one of them can be copied to a machine on its own and
# still be usable by somebody who has never seen hostings.conf.
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
    [ -n "$current" ] && { printf '%s' "$current"; return 0; }
    if [ -f "$SITES_CONF" ]; then
        v="$(conf_get "$key" "")"
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    ask "$prompt" "$default"
}

BASE_DOMAIN="$(resolve "$ARG_DOMAIN" BASE_DOMAIN "" "Your mail domain: the part after the @ in an address (the 'domain'), for example example.com")"
MAIL_ROOT="$(resolve_quiet "$ARG_MAIL_ROOT" MAIL_ROOT "/srv/mail")"
# The mail lineage is mail.<domain>, requested by add_site_certificates.sh.
# The bare domain is accepted as a fallback so a machine set up before
# 2026-09-03 keeps working, and is what the old default named outright.
if [ -z "$ARG_CERT_DIR" ]; then
    if [ -f "/etc/letsencrypt/live/mail.${BASE_DOMAIN}/fullchain.pem" ]; then
        CERT_DIR="/etc/letsencrypt/live/mail.${BASE_DOMAIN}"
    else
        CERT_DIR="/etc/letsencrypt/live/${BASE_DOMAIN}"
    fi
else
    CERT_DIR="$ARG_CERT_DIR"
fi
VMAIL_USER="vmail"
PASSWD_FILE="/etc/dovecot/users"
CONF_FILE="/etc/dovecot/conf.d/99-hosting.conf"

print_header "Dovecot"
print_status "Config:    $SITES_CONF"
print_status "Mail root: $MAIL_ROOT"
print_status "Mode:      $MODE"
spinner_start "Checking the config"

# =============================================================================
# Pre-flight. Nothing is installed or written until the store it serves exists.
# =============================================================================
ERRORS=()

[ -z "$BASE_DOMAIN" ] && ERRORS+=("No BASE_DOMAIN in $SITES_CONF")

if [ -z "$MAIL_ROOT" ]; then
    ERRORS+=("No MAIL_ROOT in $SITES_CONF")
elif [ ! -d "$MAIL_ROOT" ]; then
    ERRORS+=("The mail store does not exist: $MAIL_ROOT")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_mail_store.sh")
fi

if ! id "$VMAIL_USER" >/dev/null 2>&1; then
    ERRORS+=("User $VMAIL_USER does not exist, so nothing owns the maildirs.")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_mail_store.sh")
fi

# Every mailbox row, read exactly as add_mail_store.sh reads them. Duplicated
# rather than shared, which is this repo's rule: each script runs alone.
MAILBOXES=()
if [ ${#ARG_MAILBOXES[@]} -gt 0 ]; then
    for _m in "${ARG_MAILBOXES[@]}"; do
        case "$_m" in
            *@*) MAILBOXES+=("$_m") ;;
            *)   MAILBOXES+=("${_m}@${BASE_DOMAIN}") ;;
        esac
    done
fi

while IFS="|" read -r type name port path subdomain rest; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "mailbox" ] && continue
    name="$(echo "$name" | xargs)"
    subdomain="$(echo "$subdomain" | xargs)"
    [ "$subdomain" = "-" ] || [ -z "$subdomain" ] && subdomain="$BASE_DOMAIN"
    [ -z "$name" ] && continue
    MAILBOXES+=("${name}@${subdomain}")
done < <(if [ ${#ARG_MAILBOXES[@]} -eq 0 ] && [ -f "$SITES_CONF" ]; then grep -F '|' "$SITES_CONF" || true; fi)

# STANDING DOWN IS A STATE, NOT AN ERROR, and treating it as one is what left a
# certificate open. mail.<domain> is requested per MAILBOX row, so the last row
# leaving makes it an orphan; this script then refused to run and its config
# went on naming the lineage, so the prune could never remove it. Drift reported
# a certificate nobody could close.
#
# Dovecot keeps running with none: Postfix needs its auth and LMTP sockets
# whether or not a mailbox exists. Only the certificate stands down, back to the
# self-signed pair Debian ships, which is what 10-ssl.conf names anyway.
# CERT_DIR was chosen from BASE_DOMAIN alone, before the mailboxes were read, so
# a machine whose mailboxes are on a DIFFERENT domain asked for a lineage that
# had no reason to exist. Same fault as add_postfix.sh, which chains this script,
# and it took the whole apply down on 2026-09-07.
#
# MAILBOXES holds full addresses, so the domain is what follows the @.
if [ -z "$ARG_CERT_DIR" ] && [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
    for _m in ${MAILBOXES+"${MAILBOXES[@]}"}; do
        _d="${_m#*@}"
        for _c in "/etc/letsencrypt/live/mail.${_d}" "/etc/letsencrypt/live/${_d}"; do
            if [ -f "${_c}/fullchain.pem" ]; then
                CERT_DIR="$_c"
                print_info "No lineage for ${BASE_DOMAIN}, so TLS uses ${_c##*/}, which serves a mailbox domain."
                break 2
            fi
        done
    done
    unset _m _d _c
fi

SSL_CERT="${CERT_DIR}/fullchain.pem"
SSL_KEY="${CERT_DIR}/privkey.pem"
STAND_DOWN=0
# Stands down with no mailboxes, and also when mailboxes exist but nothing has a
# certificate yet. Refusing then stops Dovecot dead and fails the apply, which is
# worse than serving on the self-signed pair until one is issued.
if [ -z "$ARG_CERT_DIR" ] && { [ ${#MAILBOXES[@]} -eq 0 ] || [ ! -f "$SSL_CERT" ]; }; then
    [ ${#MAILBOXES[@]} -gt 0 ] && \
        print_info "No certificate for any mailbox domain yet, so TLS stands down to the self-signed pair."
    STAND_DOWN=1
    SSL_CERT="/etc/dovecot/private/dovecot.pem"
    SSL_KEY="/etc/dovecot/private/dovecot.key"
fi

# Checked here rather than after the config is written: a config naming a
# lineage that does not exist stops Dovecot dead, and it used to be written
# first and refused afterwards.
# The self-signed pair comes with dovecot-core, so on a fresh drive it cannot
# exist before the install below.
if [ ! -f "$SSL_CERT" ] && ! { [ "$STAND_DOWN" -eq 1 ] && ! dpkg -s dovecot-core >/dev/null 2>&1; }; then
    ERRORS+=("No certificate at $SSL_CERT, and Dovecot will not start without it")
    [ "$STAND_DOWN" -eq 1 ] \
        && ERRORS+=("  That is Debian's self-signed pair: apt install --reinstall ssl-cert") \
        || ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_site_certificates.sh")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    spinner_stop
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

spinner_stop
print_success "Pre-flight passed: ${#MAILBOXES[@]} mailbox(es)."
[ "$STAND_DOWN" -eq 1 ] && print_info "No mailbox rows, so TLS stands down to the self-signed pair and no Let's Encrypt lineage is held open."

# =============================================================================
# --passwd: set one password and stop.
# =============================================================================
# One asterisk per character, rather than nothing at all.
#
# `read -rs` shows no feedback whatever, so a paste that did not land and a
# paste that did look identical, and the first anyone knows is a password that
# does not work. Backspace is handled, or a typo cannot be corrected.
read_password_masked() {
    local prompt="$1" __var="$2" pw="" ch
    printf "\033[33m⚠️ %s: \033[0m" "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            "")                 break ;;
            $'\177'|$'\b')      if [ -n "$pw" ]; then pw="${pw%?}"; printf '\b \b' > /dev/tty; fi ;;
            *)                  pw="${pw}${ch}"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    printf -v "$__var" '%s' "$pw"
}

set_password() {
    local addr="$1" hash line tmp pw1 pw2
    read_password_masked "Password for $addr" pw1
    read_password_masked "Again" pw2

    if [ -z "$pw1" ] || [ "$pw1" != "$pw2" ]; then
        print_error "Passwords empty or different. $addr was not changed."
        return 1
    fi

    # doveadm hashes it, so the plaintext never reaches a file or the command
    # line, where ps would show it to every user on the machine.
    # doveadm asks twice and reads both from stdin when stdin is not a terminal.
    #
    # NOT `-p /dev/stdin`: -p takes a value, not a file, so that hashed the
    # literal string "/dev/stdin" and gave every mailbox on this machine the
    # same password. It never failed, so the fallback beside it never ran.
    hash="$(printf '%s\n%s\n' "$pw1" "$pw1" | doveadm pw -s SHA512-CRYPT 2>/dev/null)"
    unset pw1 pw2

    line="${addr}:${hash}:5000:5000::${MAIL_ROOT}/${addr#*@}/${addr%@*}::"
    tmp="$(mktemp)"
    chmod 600 "$tmp"
    grep -v "^${addr}:" "$PASSWD_FILE" 2>/dev/null > "$tmp" || true
    printf '%s\n' "$line" >> "$tmp"
    # 0640, not 0600: Dovecot's auth runs as dovecot:dovecot and reads this file
    # to look users up. 0600 let only root read it, so every delivery failed with
    # a userdb lookup error and mail deferred for good. The group is dovecot and
    # nothing wider, because the file holds password hashes.
    install -m 0640 -o root -g dovecot "$tmp" "$PASSWD_FILE"
    rm -f "$tmp"
    print_success "Password set for $addr."
}

if [ -n "$ONE_PASSWD" ]; then
    if ! command -v doveadm >/dev/null 2>&1; then
        print_error "Dovecot is not installed yet. Run this script with no options first."
        exit 1
    fi
    set_password "$ONE_PASSWD"
    systemctl reload dovecot 2>/dev/null || true
    exit 0
fi

# =============================================================================
# Install
# =============================================================================
PACKAGES=(dovecot-core dovecot-imapd dovecot-lmtpd)

MISSING=()
for p in "${PACKAGES[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ ${#MISSING[@]} -gt 0 ]; then
    if [ "$MODE" = "check" ]; then
        print_status "would install: ${MISSING[*]}"
    else
        print_status "Installing ${MISSING[*]}..."
        show_spinner_watch_only "Updating package lists" apt-get update -qq || true
        if ! show_spinner_watch_only "Installing ${MISSING[*]}" \
             apt-get install -y -qq --no-install-recommends "${MISSING[@]}"; then
            exit 1
        fi
        print_success "Installed ${MISSING[*]}"
    fi
else
    print_success "Dovecot already installed."
fi

# =============================================================================
# Configuration, in one file of our own.
#
# Debian ships a dozen conf.d files and edits to them are lost or conflicted on
# upgrade. One file, read last, holds everything this machine decides, so the
# whole configuration is greppable in one place and a package upgrade cannot
# quietly change it.
# =============================================================================
# The two sockets Postfix uses, written only once Postfix exists.
#
# They are owned by the postfix user and live under /var/spool/postfix, neither
# of which exists until that package is installed. Dovecot refuses to start on a
# socket whose owner is unknown, with "User doesn't exist: postfix", so writing
# them unconditionally means Dovecot cannot run before Postfix, and Postfix
# cannot be configured before Dovecot runs.
#
# add_postfix.sh runs this script again at the end, which is when these appear.
if id postfix >/dev/null 2>&1 && [ -d /var/spool/postfix ]; then
    POSTFIX_SOCKETS="$(cat <<'EOF'
# Postfix hands delivered mail over the first socket, and asks the second
# whether a sender may send. Owned by postfix rather than world writable.
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
EOF
)"
else
    POSTFIX_SOCKETS="# Postfix is not installed yet, so its sockets are not defined here.
# add_postfix.sh runs this script again when it is, and they appear then."
    print_info "Postfix is not installed, so the delivery socket is not configured yet."
    print_info "add_postfix.sh will run this script again and add it."
fi

CONF_CONTENT="$(cat <<EOF
# Generated by add_dovecot.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.

protocols = imap lmtp

# IMAPS only. Plain IMAP on 143 is not opened: every client made this decade
# speaks 993, and a port that exists is a port that gets tried.
service imap-login {
  inet_listener imap {
    port = 0
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

ssl = required
ssl_cert = <${SSL_CERT}
ssl_key  = <${SSL_KEY}
ssl_min_protocol = TLSv1.2
ssl_prefer_server_ciphers = yes

# Maildir, one directory per message. A backup is a file copy, which is the
# whole reason it was chosen over mbox or a database.
mail_location = maildir:${MAIL_ROOT}/%d/%n
mail_uid = ${VMAIL_USER}
mail_gid = ${VMAIL_USER}
mail_privileged_group = ${VMAIL_USER}

# Accounts live in one file of hashes, so a rebuilt machine restores mail by
# copying the store back and running this script.
passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u ${PASSWD_FILE}
}

userdb {
  driver = passwd-file
  args = username_format=%u ${PASSWD_FILE}
  default_fields = uid=${VMAIL_USER} gid=${VMAIL_USER} home=${MAIL_ROOT}/%d/%n
}

# No plaintext authentication, ever, and the login is the full address so two
# domains can each have an 'info'.
disable_plaintext_auth = yes
auth_mechanisms = plain login
auth_username_format = %Lu

${POSTFIX_SOCKETS}

# The folders a client expects to find rather than create on first use.
namespace inbox {
  inbox = yes
  mailbox Drafts {
    special_use = \\Drafts
    auto = subscribe
  }
  mailbox Sent {
    special_use = \\Sent
    auto = subscribe
  }
  mailbox Junk {
    special_use = \\Junk
    auto = subscribe
  }
  mailbox Trash {
    special_use = \\Trash
    auto = subscribe
  }
}
EOF
)"

if [ "$MODE" = "check" ]; then
    if [ ! -f "$CONF_FILE" ] || ! printf '%s\n' "$CONF_CONTENT" | cmp -s - "$CONF_FILE"; then
        print_status "would write $CONF_FILE"
    else
        print_success "$CONF_FILE already correct"
    fi
else
    TMP_CONF="$(mktemp)"
    printf '%s\n' "$CONF_CONTENT" > "$TMP_CONF"
    if [ ! -f "$CONF_FILE" ] || ! cmp -s "$TMP_CONF" "$CONF_FILE"; then
        install -m 0644 -o root -g root "$TMP_CONF" "$CONF_FILE"
        print_success "Wrote $CONF_FILE"
        NEEDS_RESTART=1
    else
        print_success "$CONF_FILE already correct."
    fi
    rm -f "$TMP_CONF"
fi

# =============================================================================
# Turn off the stock PAM passdb.
#
# Ubuntu ships 10-auth.conf with `!include auth-system.conf.ext`, which
# authenticates against SYSTEM accounts. The passdb written above is an
# addition, not a replacement, so both were live: every account on this machine
# could sign in to IMAP on 993, which ufw allows from Anywhere.
#
# Found 2026-09-04 by reading `doveadm config`, which listed two passdbs with
# `driver = pam` first. Nothing in this script had ever touched the file.
#
# A mail account is a row in hostings.conf with a hash in PASSWD_FILE. A system
# account is not a mailbox and has no maildir, so letting it authenticate buys
# nothing and exposes every shell password to the network.
# =============================================================================
AUTH_CONF="/etc/dovecot/conf.d/10-auth.conf"
if [ -f "$AUTH_CONF" ] && grep -Eq '^[[:space:]]*!include[[:space:]]+auth-system\.conf\.ext' "$AUTH_CONF"; then
    if [ "$MODE" = "check" ]; then
        print_status "would disable the PAM passdb in $AUTH_CONF"
    else
        cp -a "$AUTH_CONF" "${AUTH_CONF}.before-hosting"
        sed -i 's|^\([[:space:]]*\)\(!include[[:space:]]\+auth-system\.conf\.ext\)|\1#\2|' "$AUTH_CONF"
        print_success "Disabled the PAM passdb: only $PASSWD_FILE authenticates now."
        print_status "Previous file kept at ${AUTH_CONF}.before-hosting"
        NEEDS_RESTART=1
    fi
elif [ -f "$AUTH_CONF" ]; then
    print_success "The PAM passdb is already off."
fi

# =============================================================================
# Accounts. Existing ones are left alone, so a re-run only fills in the gaps.
# =============================================================================
# A fresh drive gets its mailbox passwords back from the secret store first,
# so only a mailbox the vault has never seen is asked for below.
if [ ! -s "$PASSWD_FILE" ] && [ "$MODE" != "check" ] && [ -f "$SCRIPT_DIR/restore_logins.sh" ]; then
    bash "$SCRIPT_DIR/restore_logins.sh" --only dovecot-users \
        || print_info "Nothing restored from the secret store, so every mailbox password is asked."
fi
if [ ! -f "$PASSWD_FILE" ] && [ "$MODE" != "check" ]; then
    install -m 0640 -o root -g dovecot /dev/null "$PASSWD_FILE"
fi

MISSING_ACCOUNTS=()
for addr in "${MAILBOXES[@]}"; do
    grep -q "^${addr}:" "$PASSWD_FILE" 2>/dev/null || MISSING_ACCOUNTS+=("$addr")
done

if [ ${#MISSING_ACCOUNTS[@]} -eq 0 ]; then
    print_success "Every mailbox already has an account."
elif [ "$MODE" = "check" ]; then
    print_status "would ask for a password for: ${MISSING_ACCOUNTS[*]}"
elif ! (exec 3</dev/tty) 2>/dev/null; then
    # NO KEYBOARD, SO NO PROMPT, AND NOT A FAILURE EITHER. This is the apply
    # running under Jenkins. Until 2026-09-06 the prompt went to /dev/tty, which
    # does not exist there, and the script exited 1: so the pipeline could not
    # run it at all, and nothing did. A mailbox created from the console became
    # a config row with no account while the job reported SUCCESS.
    #
    # The account is left unmade rather than made without a password. An account
    # with no password is one anybody can try; a missing one is a mailbox that
    # does not answer yet, which is the honest state and the recoverable one.
    #
    # Mail is not lost while it waits: Postfix will not accept for an address it
    # has no mailbox for, so the sender is told, rather than it landing where
    # nobody can read it.
    print_header "Passwords"
    print_warning "No keyboard here, so ${#MISSING_ACCOUNTS[@]} mailbox(es) have no account yet:"
    for addr in "${MISSING_ACCOUNTS[@]}"; do print_warning "  - $addr"; done
    print_action "Set each one from its row in the hosting manager, or run this script at the keyboard."
    print_info "report_drift.sh lists them as ADD mail login until then."
else
    print_header "Passwords"
    print_status "Existing accounts are left alone. Only new ones are asked for."
    for addr in "${MISSING_ACCOUNTS[@]}"; do
        set_password "$addr" || exit 1
    done
fi

if [ "$MODE" = "check" ]; then
    print_status "--check, so nothing was written."
    exit 0
fi

# =============================================================================
# Start it, and prove it is listening
# =============================================================================
if ! doveconf -n >/dev/null 2>&1; then
    print_error "Dovecot rejected the configuration, so it was not restarted."
    doveconf -n 2>&1 | tail -n 20
    exit 1
fi
print_success "Configuration is valid."

systemctl enable dovecot >/dev/null 2>&1 || true
if ! systemctl restart dovecot; then
    print_error "Dovecot did not start. Last 20 lines:"
    journalctl -u dovecot -n 20 --no-pager
    exit 1
fi

if ss -ltn 2>/dev/null | grep -q ':993 '; then
    print_success "Listening on 993 for IMAPS."
else
    print_info "Nothing is listening on 993. Check: journalctl -u dovecot -n 50"
fi

# 993 has to be reachable from the LAN and from wherever mail is read. Opened
# here rather than in a central list, because the script that needs a port is
# the script that should open it.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    if ! ufw status | grep -q "^993"; then
        ufw allow 993/tcp >/dev/null 2>&1 && print_success "Opened 993/tcp in UFW."
    fi
fi

echo ""
print_success "Dovecot is serving ${#MAILBOXES[@]} mailbox(es) over IMAPS."
print_status "Next: add_postfix.sh, which accepts mail and hands it to Dovecot."
