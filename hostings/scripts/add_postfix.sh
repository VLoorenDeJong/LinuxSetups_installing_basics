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
# Postfix: accept mail for these domains, and send mail out.
#
# Dovecot owns the mailboxes. Postfix never writes a maildir: it hands every
# delivery to Dovecot over LMTP, so there is exactly one thing that decides
# where a message lands on disk.
#
# WHAT IT LISTENS ON
#
#   25   other mail servers deliver here. No authentication, and it accepts
#        mail only for the domains listed below: an open relay is how a machine
#        ends up on a blocklist within hours.
#   587  you send through it, with a login and TLS. Never open without both.
#   465  the same thing with TLS from the first byte, which is what modern
#        clients prefer.
#
# WHO DELIVERS OUTGOING MAIL
#
# MAIL_RELAY in the config decides. Empty means this machine talks to the
# receiving server itself. A host:port means it hands everything over and their
# reputation is used instead of this line's.
#
# Switching is one config line, deliberately: mail from a residential address
# gets binned by some receivers however correct the setup is, and finding that
# out should not mean rebuilding anything.
#
# A MACHINE THAT IS NOT LIVE STILL GETS NO MAIL, AND THE MX RECORD IS WHY
#
# All three ports open on every machine. Closing 25 on a test machine looked
# careful and was not: what decides where mail is delivered is the MX record,
# which points elsewhere and is changed by hand after the swap, and the router
# forwards 25 nowhere near here. So the closed port stopped nothing that was
# going to happen, and blocked the one thing it did affect, which is testing
# delivery from the LAN. That is what a machine built beside the live one is
# for.
#
# Usage:
#   sudo bash add_postfix.sh            install and configure
#   sudo bash add_postfix.sh --check    report what would change, write nothing
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
ARG_CERT_DIR=""
ARG_RELAY=""
ARG_MAIL_DOMAINS=()

usage() {
    echo "Usage: $0 [--check] [--domain <domain>] [--hostname <mail.example.com>]" >&2
    echo "          [--cert-dir <path>] [--relay <host:port>] [--mail-domain <domain>]..." >&2
    echo "" >&2
    echo "Anything not given is taken from hostings.conf if there is one," >&2
    echo "and asked for if there is not." >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)       MODE="check"; shift ;;
        --domain)      ARG_DOMAIN="$2"; shift 2 ;;
        --hostname)    ARG_HOSTNAME="$2"; shift 2 ;;
        --cert-dir)    ARG_CERT_DIR="$2"; shift 2 ;;
        --relay)       ARG_RELAY="$2"; shift 2 ;;
        --mail-domain) ARG_MAIL_DOMAINS+=("$2"); shift 2 ;;
        -h|--help)     usage ;;
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

is_yes() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs)" in
        y|yes|true|1) return 0 ;;
        *)            return 1 ;;
    esac
}

# An argument, then the config file if there is one, then a prompt. Same order
# in every script here, so one can be copied to a machine on its own and still
# be usable by somebody who has never seen hostings.conf.
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
MAIL_HOSTNAME="${ARG_HOSTNAME:-mail.${BASE_DOMAIN}}"
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

# Never prompted for. An empty relay is a valid and common answer, so asking
# would force a decision on somebody who has not got one yet, and the wrong
# answer here is the one that silently stops mail leaving.
MAIL_RELAY="$ARG_RELAY"
if [ -z "$MAIL_RELAY" ] && [ -f "$SITES_CONF" ]; then
    MAIL_RELAY="$(conf_get MAIL_RELAY "")"
fi

RELAY_PASSWORD_FILE="/etc/postfix/relay_password"
MACHINE_IS_LIVE="no"
if [ -f "$SITES_CONF" ]; then
    RELAY_PASSWORD_FILE="$(conf_get MAIL_RELAY_PASSWORD_FILE /etc/postfix/relay_password)"
    MACHINE_IS_LIVE="$(conf_get MACHINE_IS_LIVE no)"
fi

print_header "Postfix"
print_status "Config:    $SITES_CONF"
print_status "Hostname:  $MAIL_HOSTNAME"
if [ -n "$MAIL_RELAY" ]; then
    print_status "Outgoing:  through $MAIL_RELAY"
else
    print_status "Outgoing:  straight to the receiving server"
fi
print_status "Mode:      $MODE"
spinner_start "Checking the config"

# =============================================================================
# Pre-flight. Postfix is not installed until the thing it delivers to exists.
# =============================================================================
ERRORS=()
WARNINGS=()

[ -z "$BASE_DOMAIN" ] && ERRORS+=("No BASE_DOMAIN in $SITES_CONF")

# Installed, not running. Dovecot cannot start until Postfix exists, because
# its delivery socket is owned by the postfix user, so demanding a running
# Dovecot here would make the two scripts wait for each other forever.
if ! dpkg -s dovecot-core >/dev/null 2>&1; then
    ERRORS+=("Dovecot is not installed, and Postfix delivers through it.")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_dovecot.sh")
fi

# Every domain that has a mailbox. Postfix accepts mail for these and refuses
# everything else, which is the difference between a mail server and an open
# relay somebody else uses to send spam.
MAIL_DOMAINS=()
if [ ${#ARG_MAIL_DOMAINS[@]} -gt 0 ]; then
    MAIL_DOMAINS=("${ARG_MAIL_DOMAINS[@]}")
fi

while IFS='|' read -r type name port path subdomain rest; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "mailbox" ] && continue
    subdomain="$(echo "$subdomain" | xargs)"
    [ "$subdomain" = "-" ] || [ -z "$subdomain" ] && subdomain="$BASE_DOMAIN"
    case " ${MAIL_DOMAINS[*]} " in
        *" $subdomain "*) ;;
        *) MAIL_DOMAINS+=("$subdomain") ;;
    esac
done < <(if [ ${#ARG_MAIL_DOMAINS[@]} -eq 0 ] && [ -f "$SITES_CONF" ]; then grep -F '|' "$SITES_CONF" || true; fi)

# STANDING DOWN IS A STATE, NOT AN ERROR. The same reasoning as add_dovecot.sh:
# mail.<domain> is requested per MAILBOX row, so the last row leaving makes it an
# orphan, and a main.cf that goes on naming it is what stops the prune removing
# it. Postfix keeps running either way, because it relays for the applications
# over loopback whether or not a mailbox exists. Only the certificate stands
# down, to the self-signed pair Debian ships.
# CERT_DIR was chosen from BASE_DOMAIN alone, before the mailbox rows were read.
# A machine whose mailboxes are on a DIFFERENT domain therefore looked for a
# lineage that had no reason to exist, and the pre-flight refused.
#
# Measured 2026-09-07: every example.com row was deleted and the mailboxes
# were contact@ and admin@example.net. mail.example.net had
# just been issued in the same apply, and Postfix still asked for
# /etc/letsencrypt/live/example.com/fullchain.pem and failed the whole job.
#
# So the mail domains get a say, in order of preference, and BASE_DOMAIN keeps
# its place at the front for the machine where it is right.
if [ -z "$ARG_CERT_DIR" ] && [ ! -f "${CERT_DIR}/fullchain.pem" ]; then
    for _d in ${MAIL_DOMAINS+"${MAIL_DOMAINS[@]}"}; do
        for _c in "/etc/letsencrypt/live/mail.${_d}" "/etc/letsencrypt/live/${_d}"; do
            if [ -f "${_c}/fullchain.pem" ]; then
                CERT_DIR="$_c"
                print_info "No lineage for ${BASE_DOMAIN}, so TLS uses ${_c##*/}, which serves a mailbox domain."
                break 2
            fi
        done
    done
    unset _d _c
fi

SSL_CERT="${CERT_DIR}/fullchain.pem"
SSL_KEY="${CERT_DIR}/privkey.pem"
STAND_DOWN=0
# Stands down when there is no mailbox, and ALSO when there are mailboxes but no
# certificate anywhere for them. Refusing in that case fails the whole apply and
# leaves the machine part way changed, which is worse than serving mail on the
# self-signed pair until a certificate arrives: Postfix relays for the
# applications over loopback either way.
if [ -z "$ARG_CERT_DIR" ] && { [ ${#MAIL_DOMAINS[@]} -eq 0 ] || [ ! -f "$SSL_CERT" ]; }; then
    [ ${#MAIL_DOMAINS[@]} -gt 0 ] && \
        print_info "No certificate for any mailbox domain yet, so TLS stands down to the self-signed pair."
    STAND_DOWN=1
    SSL_CERT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
    SSL_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"
fi

if [ ! -f "$SSL_CERT" ]; then
    ERRORS+=("No certificate at $SSL_CERT")
    [ "$STAND_DOWN" -eq 1 ] \
        && ERRORS+=("  That is Debian's self-signed pair: apt install --reinstall ssl-cert") \
        || ERRORS+=("  Run: sudo bash $SCRIPT_DIR/add_site_certificates.sh")
fi

if [ -n "$MAIL_RELAY" ]; then
    case "$MAIL_RELAY" in
        *:*) ;;
        *) ERRORS+=("MAIL_RELAY = '$MAIL_RELAY' has no port. Write it as host:port, for example smtp.example.net:587") ;;
    esac
    if [ ! -f "$RELAY_PASSWORD_FILE" ]; then
        WARNINGS+=("No login at $RELAY_PASSWORD_FILE, so the relay is used without one.")
        WARNINGS+=("  Most ISP servers accept their own customers without a login. If yours does not:")
        WARNINGS+=("    sudo install -m 600 -o root -g root /dev/null $RELAY_PASSWORD_FILE")
        WARNINGS+=("    then put one line in it: user:password")
    fi
fi

if ! is_yes "$MACHINE_IS_LIVE"; then
    WARNINGS+=("MACHINE_IS_LIVE = no. Port 25 is open, but no mail from the internet")
    WARNINGS+=("  can arrive: the MX record still points elsewhere, and the router does")
    WARNINGS+=("  not forward 25 here. That record is the gate, and changing it is a")
    WARNINGS+=("  deliberate manual step after the drive swap.")
    WARNINGS+=("  25 is open so delivery CAN be tested from the LAN, which is the whole")
    WARNINGS+=("  point of a machine built beside the live one.")
fi

spinner_stop
if [ ${#WARNINGS[@]} -gt 0 ]; then
    print_info "Warnings, which do not stop the run:"
    for w in "${WARNINGS[@]}"; do print_info "  $w"; done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    spinner_stop
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

spinner_stop
print_success "Pre-flight passed: ${#MAIL_DOMAINS[@]} domain(s) will be accepted."
[ "$STAND_DOWN" -eq 1 ] && print_info "No mailbox rows, so TLS stands down to the self-signed pair and no Let's Encrypt lineage is held open."

# =============================================================================
# Install
# =============================================================================
if ! dpkg -s postfix >/dev/null 2>&1; then
    if [ "$MODE" = "check" ]; then
        print_status "would install postfix"
    else
        print_status "Installing postfix..."
        MISSING=(postfix)
        # Preseeded, because the package otherwise opens a full-screen dialogue
        # and an unattended install stops dead on it.
        debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Internet Site
postfix postfix/mailname string ${MAIL_HOSTNAME}
EOF
        show_spinner_watch_only "Updating package lists" apt-get update -qq || true
        if ! show_spinner_watch_only "Installing ${MISSING[*]}" \
             apt-get install -y -qq --no-install-recommends "${MISSING[@]}"; then
            exit 1
        fi
        print_success "Installed ${MISSING[*]}"
    fi
else
    print_success "Postfix already installed."
fi

# =============================================================================
# main.cf, written whole rather than patched.
#
# postconf -e edits in place, which makes the running configuration a history of
# every run rather than a statement of what this machine wants. Written whole,
# the file IS the config and a diff shows exactly what changed.
# =============================================================================
RELAY_LINES=""
if [ -n "$MAIL_RELAY" ]; then
    RELAY_LINES="relayhost = [${MAIL_RELAY%:*}]:${MAIL_RELAY##*:}"
    if [ -f "$RELAY_PASSWORD_FILE" ]; then
        RELAY_LINES="${RELAY_LINES}
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt"
    fi
fi

MAIN_CF="$(cat <<EOF
# Generated by add_postfix.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.

compatibility_level = 3.6
myhostname = ${MAIL_HOSTNAME}
myorigin = \$myhostname

# What this machine accepts mail FOR. Everything else is refused, which is the
# line between a mail server and an open relay somebody else sends spam through.
mydestination =
virtual_mailbox_domains = ${MAIL_DOMAINS[*]}

# Postfix never writes a maildir. Dovecot does, over this socket, so exactly one
# thing decides where a message lands on disk.
virtual_transport = lmtp:unix:private/dovecot-lmtp

# Only this machine may send without logging in. Anything else must authenticate
# on 587 or 465.
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128

# Dovecot answers "may this person send", using the same accounts it serves
# IMAP with. One list of users, not two.
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = no

smtpd_tls_cert_file = ${SSL_CERT}
smtpd_tls_key_file  = ${SSL_KEY}
smtpd_tls_security_level = may
smtpd_tls_protocols = >=TLSv1.2
smtp_tls_security_level = may
smtp_tls_protocols = >=TLSv1.2

# A sender may only claim an address they own. Without this, anyone with any
# account can send as anyone else here.
#
# NOT \$virtual_mailbox_maps, which is the usual shortcut and is wrong here:
# that map's value is a maildir path, so the comparison against the SASL login
# never matched and every authenticated send was refused. The real map is
# written further down and is address -> address.
smtpd_sender_login_maps = hash:/etc/postfix/sender_login_map

smtpd_recipient_restrictions =
    permit_mynetworks
    permit_sasl_authenticated
    reject_unauth_destination

message_size_limit = 52428800
${RELAY_LINES}
EOF
)"

MASTER_APPEND="$(cat <<'EOF'
# Generated by add_postfix.sh. The submission ports, both requiring a login and
# TLS. 587 upgrades to TLS, 465 is TLS from the first byte, which is what modern
# clients prefer.
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
  -o smtpd_sender_restrictions=reject_sender_login_mismatch
EOF
)"

if [ "$MODE" = "check" ]; then
    # Compared, not assumed. A check that says "would write" about a file it
    # just wrote and that has not changed is noise, and noise gets skipped.
    TMP="$(mktemp)"
    printf '%s\n' "$MAIN_CF" > "$TMP"
    if [ ! -f /etc/postfix/main.cf ] || ! cmp -s "$TMP" /etc/postfix/main.cf; then
        print_status "would write /etc/postfix/main.cf"
    else
        print_success "/etc/postfix/main.cf already correct"
    fi
    rm -f "$TMP"

    if grep -q "^submission inet" /etc/postfix/master.cf 2>/dev/null; then
        print_success "the submission ports are already in /etc/postfix/master.cf"
    else
        print_status "would add the submission ports to /etc/postfix/master.cf"
    fi

    print_status "--check, so nothing was written."
    exit 0
fi

TMP="$(mktemp)"
printf '%s\n' "$MAIN_CF" > "$TMP"
if [ ! -f /etc/postfix/main.cf ] || ! cmp -s "$TMP" /etc/postfix/main.cf; then
    install -m 0644 -o root -g root "$TMP" /etc/postfix/main.cf
    print_success "Wrote /etc/postfix/main.cf"
fi
rm -f "$TMP"

# master.cf is appended to rather than replaced: it carries the package's own
# service definitions, and rewriting it whole would mean owning all of them.
if ! grep -q "^submission inet" /etc/postfix/master.cf; then
    printf '\n%s\n' "$MASTER_APPEND" >> /etc/postfix/master.cf
    print_success "Added the submission ports to /etc/postfix/master.cf"
fi

# The list of addresses that exist here, rebuilt from the config every run. A
# recipient not in it is refused at the door rather than accepted and bounced.
VMAP="/etc/postfix/virtual_mailbox_map"
TMP="$(mktemp)"
# A disabled mailbox still receives and still logs in, so it stays in this map.
# What it loses is the right to send, which is the map below.
NOSEND="$(mktemp)"
while IFS='|' read -r type name port path subdomain datasource options auth \
                      repo branch rowenvs authusers repomode runtime enabled; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "mailbox" ] && continue
    name="$(echo "$name" | xargs)"
    subdomain="$(echo "$subdomain" | xargs)"
    [ "$subdomain" = "-" ] || [ -z "$subdomain" ] && subdomain="$BASE_DOMAIN"
    [ -z "$name" ] && continue
    printf '%s@%s %s/%s/\n' "$name" "$subdomain" "$subdomain" "$name" >> "$TMP"

    # The CR is stripped before xargs, which does not strip it. This is the
    # LAST field on the line, so a CRLF config reaches it, and "no\r" would
    # have left a disabled mailbox with its right to send.
    enabled="${enabled//$'\r'/}"
    enabled="$(echo "${enabled:-}" | sed 's/#.*//' | xargs | tr '[:upper:]' '[:lower:]')"
    { [ -z "$enabled" ] || [ "$enabled" = "-" ]; } && enabled="yes"
    [ "$enabled" = "no" ] && printf '%s@%s\n' "$name" "$subdomain" >> "$NOSEND"
done < <(if [ ${#ARG_MAIL_DOMAINS[@]} -eq 0 ] && [ -f "$SITES_CONF" ]; then grep -F '|' "$SITES_CONF" || true; fi)

if [ ! -f "$VMAP" ] || ! cmp -s "$TMP" "$VMAP"; then
    install -m 0644 -o root -g root "$TMP" "$VMAP"
    print_success "Wrote $VMAP"
fi
rm -f "$TMP"
postmap "$VMAP"
postconf -e "virtual_mailbox_maps = hash:$VMAP"

# Who OWNS an address, which is a different question from where its mail lands.
#
# smtpd_sender_login_maps used to point at virtual_mailbox_maps, which is the
# shortcut every tutorial gives and is wrong for this layout: that map's value
# is a maildir path. reject_sender_login_mismatch then compared the SASL login
# `contact@example.com` against the value `example.com/contact/`, found them
# different, and refused with "Sender address rejected: not owned by user".
#
# The consequence was total and silent: no authenticated client could send from
# this machine at all, and nothing said so until webmail was first used on
# 2026-08-28. Receiving was never affected, which is why it went unnoticed.
#
# Here the login IS the address, so every line maps an address to itself.
#
# A disabled mailbox is left out of this map entirely. Nobody then owns the
# address, so reject_sender_login_mismatch refuses any attempt to send as it,
# while its mail still arrives and its password still works. That is disable
# for a mailbox, and it needs no new map and no new restriction.
SLMAP="/etc/postfix/sender_login_map"
TMP="$(mktemp)"
while IFS=' ' read -r addr _; do
    [ -n "$addr" ] || continue
    grep -qxF "$addr" "$NOSEND" 2>/dev/null && continue
    printf '%s %s\n' "$addr" "$addr" >> "$TMP"
done < "$VMAP"

if [ ! -f "$SLMAP" ] || ! cmp -s "$TMP" "$SLMAP"; then
    install -m 0644 -o root -g root "$TMP" "$SLMAP"
    print_success "Wrote $SLMAP"
fi
rm -f "$TMP"
postmap "$SLMAP"
postconf -e "smtpd_sender_login_maps = hash:$SLMAP"
if [ -s "$NOSEND" ]; then
    print_info "Cannot send, by configuration: $(tr '\n' ' ' < "$NOSEND")"
fi
rm -f "$NOSEND"

# The forward map. manage_mail.sh writes a line here when a mailbox is removed
# with "keep the files": new mail to the old address is redirected to
# contact@<domain> while the maildir stays on disk. Created empty so
# virtual_alias_maps has a file to point at, and postmapped so the .db exists
# before the first forward. The file is left as it is on a re-run: its contents
# are managed by the console, not by this script.
FWDMAP="/etc/postfix/virtual_forwards"
[ -f "$FWDMAP" ] || : > "$FWDMAP"
chmod 644 "$FWDMAP"
postmap "$FWDMAP"
postconf -e "virtual_alias_maps = hash:$FWDMAP"

if [ -n "$MAIL_RELAY" ] && [ -f "$RELAY_PASSWORD_FILE" ]; then
    # Postfix wants "host user:password", and the file holds only the login, so
    # the host is added here rather than asked for twice.
    TMP="$(mktemp)"
    chmod 600 "$TMP"
    printf '[%s]:%s %s\n' "${MAIL_RELAY%:*}" "${MAIL_RELAY##*:}" \
        "$(head -n1 "$RELAY_PASSWORD_FILE")" > "$TMP"
    install -m 0600 -o root -g root "$TMP" /etc/postfix/sasl_passwd
    rm -f "$TMP"
    postmap /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd.db
    print_success "Relay login installed."
fi

# =============================================================================
# Start it, and say what is reachable
# =============================================================================
# The exit code decides, not whether anything was printed. `postfix check` warns
# about things that are not errors, and the old test treated any output at all
# as a rejection.
#
# Measured 2026-08-31: this machine's only output is "warning:
# /var/spool/postfix/etc/resolv.conf and /etc/resolv.conf differ", which is the
# chroot copy being out of date and does not stop Postfix running. Every run of
# this script exited 1 here, so Postfix was never restarted and add_dovecot.sh
# below was never reached.
CHECK_RC=0
CHECK_OUT="$(postfix check 2>&1)" || CHECK_RC=$?

if [ "$CHECK_RC" -ne 0 ]; then
    print_error "Postfix rejected the configuration, so it was not restarted."
    printf '%s\n' "$CHECK_OUT"
    exit 1
fi

if [ -n "$CHECK_OUT" ]; then
    print_warning "Postfix had something to say, and none of it makes the configuration invalid:"
    printf '%s\n' "$CHECK_OUT"
fi
print_success "Configuration is valid."

# Now that the postfix user and /var/spool/postfix exist, Dovecot can be given
# the sockets it could not define before, and started. Running the whole script
# again rather than patching its config file: it is the only writer of that
# file, and a second one would be a second answer to what Dovecot is configured
# to do.
if [ -x "$SCRIPT_DIR/add_dovecot.sh" ] || [ -f "$SCRIPT_DIR/add_dovecot.sh" ]; then
    print_status "Giving Dovecot its delivery socket, now that postfix exists..."
    # SITES_CONF PASSED ON, not inherited. It is a plain variable here, never
    # exported, so the child fell back to its own default. Harmless while both
    # resolved to the same file; wrong the moment the apply hands a candidate,
    # which is exactly what maintain_services.sh does now that it runs this.
    # Postfix would then serve the new config and Dovecot the old one.
    SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/add_dovecot.sh" || {
        print_error "add_dovecot.sh failed, so mail cannot be delivered into a mailbox."
        exit 1
    }
fi

# A mail domain arriving from the console got a mailbox and no DKIM key, because
# add_rspamd.sh was only ever run by hand or by start_install.sh. Chained here,
# before the restart below, so the milter settings it writes are picked up:
# existing keys are never regenerated, so re-running it costs nothing.
#
# Not fatal. Unsigned mail still delivers, where undelivered mail does not.
if [ -f "$SCRIPT_DIR/add_rspamd.sh" ]; then
    print_status "Making sure every mail domain has a DKIM key..."
    SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/add_rspamd.sh" || \
        print_error "add_rspamd.sh failed, so outgoing mail is NOT signed."
fi

systemctl enable postfix >/dev/null 2>&1 || true
if ! systemctl restart postfix; then
    print_error "Postfix did not start. Last 20 lines:"
    journalctl -u postfix -n 20 --no-pager
    exit 1
fi

# 587 and 465 are for you. 25 is for other mail servers.
#
# All three open regardless of MACHINE_IS_LIVE. Closing 25 on a machine that is
# not live looked careful and was not: what decides whether mail arrives is the
# MX record, which points elsewhere and is changed by hand after the swap, and
# the router forwards 25 nowhere near here. So the closed port prevented nothing
# that was going to happen, and blocked the only thing it affected, which is
# testing delivery from the LAN. That is what a machine built beside the live one
# is for.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    for p in 25 587 465; do
        ufw status | grep -q "^${p}" || ufw allow "${p}/tcp" >/dev/null 2>&1
    done
    print_success "Opened 25, 587 and 465 in UFW."
fi

echo ""
print_success "Postfix accepts mail for: ${MAIL_DOMAINS[*]}"
print_status "Next: add_rspamd.sh, which signs outgoing mail and filters incoming."
