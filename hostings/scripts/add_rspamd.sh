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
# Rspamd: sign what goes out, filter what comes in.
#
# TWO JOBS, AND THE FIRST ONE IS WHY THIS EXISTS
#
# 1. DKIM SIGNING. Mail leaving a home internet line is treated as suspicious
#    by default. A DKIM signature is the receiver's proof that the message
#    really came from your domain and was not altered, and without one most of
#    what you send lands in a spam folder however correct everything else is.
#
# 2. SPAM FILTERING on the way in, and it is not the lesser half. A published
#    contact address collects everything, so the filter has to file the spam
#    away and get better at it over time, not just label it.
#
# THE SIGNING KEY IS GENERATED HERE AND ITS PUBLIC HALF GOES IN DNS
#
# One key per domain, under /var/lib/rspamd/dkim, which is rspamd's own packaged
# default. It is deliberately NOT in the mail store: that is 0700 vmail, which
# rspamd cannot traverse, so a key kept there cannot be read by the only process
# that needs it and nothing gets signed. add_mail_store.sh backs this directory
# up alongside the mail, so the key still travels with a restore.
#
# The private half never leaves the machine. The public half is written to DNS
# by add_mail_dns_records.sh, and printed here as well for a manual paste.
#
# Usage:
#   sudo bash add_rspamd.sh              install, configure, make keys
#   sudo bash add_rspamd.sh --check      report what would change
#   sudo bash add_rspamd.sh --dns        print the DNS records again and stop
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
ARG_MAIL_ROOT=""
ARG_SELECTOR=""
ARG_DKIM_DIR=""
ARG_DOMAINS=()

usage() {
    echo "Usage: $0 [--check] [--dns] [--mail-root <path>] [--selector <name>]" >&2
    echo "          [--domain <domain>]..." >&2
    echo "" >&2
    echo "Anything not given is taken from hostings.conf if there is one," >&2
    echo "and asked for if there is not." >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --check)     MODE="check"; shift ;;
        --dns)       MODE="dns"; shift ;;
        --mail-root) ARG_MAIL_ROOT="$2"; shift 2 ;;
        --selector)  ARG_SELECTOR="$2"; shift 2 ;;
        --dkim-dir)  ARG_DKIM_DIR="$2"; shift 2 ;;
        --domain)    ARG_DOMAINS+=("$2"); shift 2 ;;
        -h|--help)   usage ;;
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

# An argument, then the config file if there is one, then a prompt. Same order
# in every script here.
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

BASE_DOMAIN=""
[ -f "$SITES_CONF" ] && BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
MAIL_ROOT="$(resolve_quiet "$ARG_MAIL_ROOT" MAIL_ROOT "/srv/mail")"
# rspamd's packaged default, named in /etc/rspamd/modules.d/dkim_signing.conf.
# A signing key is the signer's credential, not mail data, and keeping it inside
# the mail store meant rspamd could not traverse a 0700 vmail directory to reach
# its own key: nothing was signed while every script reported success.
DKIM_DIR="$(resolve_quiet "$ARG_DKIM_DIR" MAIL_DKIM_DIR "/var/lib/rspamd/dkim")"

# The selector names this key in DNS, and TransIP already publishes its own
# under transip-a/b/c. Anything not already taken works; changing it later means
# republishing the record.
DKIM_SELECTOR="$(resolve_quiet "$ARG_SELECTOR" MAIL_DKIM_SELECTOR "mail")"
LOCAL_D="/etc/rspamd/local.d"

# The one place the key filename is spelled out. rspamd's own default form, with
# the selector in the name, so a selector can be rotated without overwriting the
# key whose public half is still published in DNS.
key_path() { printf '%s/%s.%s.key' "$DKIM_DIR" "$1" "$DKIM_SELECTOR"; }
pub_path() { printf '%s/%s.%s.pub' "$DKIM_DIR" "$1" "$DKIM_SELECTOR"; }

# Every domain with a mailbox, read the same way every other mail script reads
# them. Duplicated on purpose: each script here runs alone.
MAIL_DOMAINS=()
if [ ${#ARG_DOMAINS[@]} -gt 0 ]; then
    MAIL_DOMAINS=("${ARG_DOMAINS[@]}")
    [ -z "$BASE_DOMAIN" ] && BASE_DOMAIN="${MAIL_DOMAINS[0]}"
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
done < <(if [ ${#ARG_DOMAINS[@]} -eq 0 ] && [ -f "$SITES_CONF" ]; then grep -F '|' "$SITES_CONF" || true; fi)

print_header "Rspamd"
print_status "Config:    $SITES_CONF"
print_status "Domains:   ${MAIL_DOMAINS[*]:-none}"
print_status "DKIM keys: $DKIM_DIR"
print_status "Mode:      $MODE"
spinner_start "Checking the config"

# =============================================================================
# The DNS records this needs, printed rather than written.
#
# add_dns_records.sh manages CNAMEs pointing at an apex and nothing else, on
# purpose: mail records are TransIP's to run today. So these are printed as
# text to paste, and saying that plainly is better than a script that half
# manages them.
# =============================================================================
print_dns_records() {
    local dom pub
    print_header "DNS records to add"
    print_status "None of these are written for you. Paste them in the control panel."

    for dom in "${MAIL_DOMAINS[@]}"; do
        echo ""
        printf "\033[36m  %s\033[0m\n" "$dom"

        if [ -f "$(pub_path "$dom")" ]; then
            pub="$(tr -d '\n' < "$(pub_path "$dom")" \
                   | sed 's/-----BEGIN PUBLIC KEY-----//; s/-----END PUBLIC KEY-----//; s/ //g')"
            echo "    TXT   ${DKIM_SELECTOR}._domainkey   v=DKIM1; k=rsa; p=${pub}"
        else
            print_info "    no DKIM key yet for $dom"
        fi

        # Says "only this machine sends for this domain, reject anything else".
        # -all rather than ~all: a soft fail is advisory and receivers vary in
        # whether they act on it at all.
        echo "    TXT   @                        v=spf1 mx -all"

        # Tells receivers what to do with mail that fails both checks, and where
        # to report it. p=none to start: it asks for reports without asking
        # anyone to reject, which is the only safe first setting.
        echo "    TXT   _dmarc                   v=DMARC1; p=none; rua=mailto:postmaster@${dom}"

        echo "    MX    @        10              mail.${BASE_DOMAIN}"
    done

    echo ""
    print_info "TransIP already has transip-a/b/c._domainkey CNAME records."
    print_info "Those sign mail sent through THEIR servers. Leave them: they do"
    print_info "not conflict, because this key uses a different selector."
    echo ""
    print_action "The MX record is the switch that makes mail arrive HERE."
    print_action "Add it last, after the drive swap, or mail stops reaching TransIP"
    print_info "and starts reaching a machine that is not live yet."
}

if [ "$MODE" = "dns" ]; then
    print_dns_records
    exit 0
fi

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()

[ -z "$BASE_DOMAIN" ] && ERRORS+=("No BASE_DOMAIN in $SITES_CONF")
[ ${#MAIL_DOMAINS[@]} -eq 0 ] && ERRORS+=("No mailbox rows in $SITES_CONF, so there is nothing to sign for")

if [ -z "$MAIL_ROOT" ] || [ ! -d "$MAIL_ROOT" ]; then
    ERRORS+=("The mail store does not exist: ${MAIL_ROOT:-<unset>}")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_mail_store.sh")
fi

if ! systemctl is-active --quiet postfix 2>/dev/null; then
    ERRORS+=("Postfix is not running, and this filters its mail.")
    ERRORS+=("  Run it first: sudo bash $SCRIPT_DIR/add_postfix.sh")
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
# =============================================================================
PACKAGES=(rspamd redis-server)
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
    print_success "Rspamd and Redis already installed."
fi

# =============================================================================
# DKIM keys, one per domain. Existing keys are never regenerated: the public
# half is already in DNS, and replacing the private half breaks every signature
# until the record catches up.
# =============================================================================
if [ "$MODE" != "check" ]; then
    mkdir -p "$DKIM_DIR"
    chmod 0700 "$DKIM_DIR"

    for dom in "${MAIL_DOMAINS[@]}"; do
        if [ ! -f "$(key_path "$dom")" ] && [ -f "$SCRIPT_DIR/restore_logins.sh" ]; then
            bash "$SCRIPT_DIR/restore_logins.sh" --only "dkim-$dom" || true
        fi
        if [ -f "$(key_path "$dom")" ]; then
            if [ ! -f "$(pub_path "$dom")" ] && ! openssl rsa -in "$(key_path "$dom")" -pubout \
                    -out "$(pub_path "$dom")" 2>/dev/null; then
                print_error "The DKIM key for $dom is not a readable RSA key: $(key_path "$dom")"
                print_action "Remove it and re-run, to make a new one: the DNS record then changes too."
                exit 1
            fi
            print_success "DKIM key for $dom already exists."
            continue
        fi
        openssl genrsa -out "$(key_path "$dom")" 2048 2>/dev/null
        openssl rsa -in "$(key_path "$dom")" -pubout \
            -out "$(pub_path "$dom")" 2>/dev/null
        print_success "Made a DKIM key for $dom"
    done

    chown -R _rspamd:_rspamd "$DKIM_DIR" 2>/dev/null || \
        chown -R rspamd:rspamd "$DKIM_DIR" 2>/dev/null || true
    chmod 0600 "$DKIM_DIR"/*.key 2>/dev/null || true
fi

# =============================================================================
# Configuration, in local.d, which is the directory Debian's package leaves for
# exactly this and does not overwrite on upgrade.
# =============================================================================
write_conf() {
    local file="$1" content="$2" tmp
    tmp="$(mktemp)"
    printf '%s\n' "$content" > "$tmp"
    if [ ! -f "$file" ] || ! cmp -s "$tmp" "$file"; then
        if [ "$MODE" = "check" ]; then
            print_status "would write $file"
        else
            install -m 0644 -o root -g root "$tmp" "$file"
            print_success "Wrote $file"
            NEEDS_RESTART=1
        fi
    fi
    rm -f "$tmp"
}

[ "$MODE" != "check" ] && mkdir -p "$LOCAL_D"

write_conf "${LOCAL_D}/dkim_signing.conf" "$(cat <<EOF
# Generated by add_rspamd.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it.

# One key per domain, in rspamd's own directory: the mail store is 0700 vmail
# and rspamd cannot traverse it. Lose these and every receiver rejects your
# signatures until the DNS records are replaced too, so add_mail_store.sh backs
# this directory up alongside the mail itself.
path = "${DKIM_DIR}/\$domain.\$selector.key";
selector = "${DKIM_SELECTOR}";
allow_username_mismatch = true;
use_domain = "header";
sign_authenticated = true;
sign_local = true;
EOF
)"

write_conf "${LOCAL_D}/worker-proxy.inc" "$(cat <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
#
# The milter Postfix talks to. Loopback only: nothing outside this machine has
# any business asking rspamd to score a message.
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF
)"

write_conf "${LOCAL_D}/worker-normal.inc" "$(cat <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
bind_socket = "127.0.0.1:11333";
EOF
)"

write_conf "${LOCAL_D}/worker-controller.inc" "$(cat <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
#
# The web interface. Loopback only, and deliberately without an Apache door in
# front of it: nothing here needs looking at day to day, and reaching it over an
# SSH tunnel is one command when it does.
#
#   ssh -L 11334:127.0.0.1:11334 <user>@<this machine>
#   then open http://127.0.0.1:11334
bind_socket = "127.0.0.1:11334";
EOF
)"

write_conf "${LOCAL_D}/actions.conf" "$(cat <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
#
# Nothing is rejected outright. A false positive that bounces is worse than one
# sitting in Junk where it can be found, and on a contact address the false
# positive is the message that mattered. reject is left off entirely.
#
# add_header at 6 is what the Sieve rule below files into Junk.
greylist = 4;
add_header = 6;
rewrite_subject = null;
reject = null;
EOF
)"

if [ "$MODE" = "check" ]; then
    print_status "--check, so nothing was written."
    exit 0
fi

# =============================================================================
# Point Postfix at it
#
# Appended with postconf rather than rewriting main.cf, because add_postfix.sh
# owns that file and a second writer would fight it. These four keys are the
# only ones this script touches.
# =============================================================================
postconf -e "smtpd_milters = inet:127.0.0.1:11332"
postconf -e "non_smtpd_milters = inet:127.0.0.1:11332"
postconf -e "milter_protocol = 6"
# Mail is delivered even if rspamd is down. A filter that cannot run is not a
# reason to refuse a customer's message.
postconf -e "milter_default_action = accept"
print_success "Postfix now passes mail through rspamd."

systemctl enable redis-server rspamd >/dev/null 2>&1 || true
systemctl restart redis-server 2>/dev/null || true

if ! systemctl restart rspamd; then
    print_error "Rspamd did not start. Last 20 lines:"
    journalctl -u rspamd -n 20 --no-pager
    exit 1
fi
systemctl reload postfix

# Waited for rather than checked once. systemctl restart returns as soon as the
# unit is started, and rspamd binds its sockets a moment later, so an immediate
# look reports nothing listening on a service that is perfectly fine.
_waited=0
while [ "$_waited" -lt 15 ]; do
    if ss -ltn 2>/dev/null | grep -q '127.0.0.1:11332'; then
        print_success "Milter listening on 127.0.0.1:11332."
        break
    fi
    sleep 1
    _waited=$((_waited + 1))
done
if [ "$_waited" -ge 15 ]; then
    print_action "Nothing on 11332 after 15s. Check: journalctl -u rspamd -n 50"
fi

# =============================================================================
# Filing and learning
#
# Scoring mail is half the job. Without these two pieces rspamd puts a header on
# a message and drops it in the inbox anyway, and never gets better at it.
#
# 1. Sieve files anything scored as spam into Junk.
# 2. IMAP Sieve watches the Junk folder. Moving a message IN teaches rspamd it
#    was spam; dragging one OUT teaches the opposite.
#
# The second is what matters on an address like contact@. A generic filter is
# adequate; one trained on the mail YOU actually get is what stops the last few
# per cent, and the training happens as a side effect of tidying your inbox
# rather than as a chore.
# =============================================================================
print_header "Filing and learning"

SIEVE_PACKAGES=(dovecot-sieve dovecot-managesieved)
SIEVE_MISSING=()
for p in "${SIEVE_PACKAGES[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || SIEVE_MISSING+=("$p")
done

if [ ${#SIEVE_MISSING[@]} -gt 0 ]; then
    if ! show_spinner_watch_only "Installing ${SIEVE_MISSING[*]}" \
         apt-get install -y -qq --no-install-recommends "${SIEVE_MISSING[@]}"; then
        exit 1
    fi
    print_success "Installed ${SIEVE_MISSING[*]}"
fi

mkdir -p /etc/dovecot/sieve /var/lib/dovecot/sieve

# Runs before the user's own rules, so a message scored as spam is filed even if
# somebody later writes their own filters.
cat > /etc/dovecot/sieve/spam-to-junk.sieve <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
require ["fileinto", "mailbox"];

# rspamd adds this header when a message scores above the add_header threshold.
if header :contains "X-Spam" "Yes" {
    fileinto :create "Junk";
    stop;
}
EOF

# Told rspamd, as the vmail user, so the learned data belongs to the same place
# the mail does. Failure is ignored on purpose: a training call that errors must
# never stop a message being moved.
cat > /usr/local/sbin/rspamd-learn-spam.sh <<'EOF'
#!/bin/sh
# Generated by add_rspamd.sh. Called by Dovecot when a message enters Junk.
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_spam
EOF

cat > /usr/local/sbin/rspamd-learn-ham.sh <<'EOF'
#!/bin/sh
# Generated by add_rspamd.sh. Called by Dovecot when a message leaves Junk.
exec /usr/bin/rspamc -h 127.0.0.1:11334 learn_ham
EOF

chmod 0755 /usr/local/sbin/rspamd-learn-spam.sh /usr/local/sbin/rspamd-learn-ham.sh

cat > /etc/dovecot/conf.d/99-hosting-sieve.conf <<'EOF'
# Generated by add_rspamd.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it.
#
# Separate from 99-hosting.conf, which add_dovecot.sh owns. Two scripts
# writing one file is two answers to what Dovecot is configured to do.

protocols = $protocols sieve

plugin {
  sieve_before = /etc/dovecot/sieve/spam-to-junk.sieve
  sieve_plugins = sieve_imapsieve sieve_extprograms
  sieve_pipe_bin_dir = /usr/local/sbin
  sieve_global_extensions = +vnd.dovecot.pipe

  # Moved INTO Junk: it was spam, and rspamd is told so.
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/learn-spam.sieve

  # Moved OUT of Junk into anything else: it was not spam after all.
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Junk
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/learn-ham.sieve
}

service managesieve-login {
  inet_listener sieve {
    port = 0
  }
}
EOF

cat > /etc/dovecot/sieve/learn-spam.sieve <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "rspamd-learn-spam.sh";
EOF

cat > /etc/dovecot/sieve/learn-ham.sieve <<'EOF'
# Generated by add_rspamd.sh. Do not edit by hand.
require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "rspamd-learn-ham.sh";
EOF

# Compiled here rather than at first use: a syntax error found now is a line in
# this output, and found later is mail silently not being filed.
#
# Only the filing rule is compiled here. The two learn scripts use capabilities
# that exist only once Dovecot has loaded the imapsieve and extprograms plugins,
# and sievec on its own does not: it reported "unknown Sieve capability" for
# scripts that are correct. Dovecot compiles those itself, with the plugins
# present, and logs it if they are wrong.
if command -v sievec >/dev/null 2>&1; then
    if ! sievec /etc/dovecot/sieve/spam-to-junk.sieve 2>/tmp/sievec.$$; then
        print_error "The spam filing rule does not compile:"
        cat /tmp/sievec.$$
        rm -f /tmp/sievec.$$
        exit 1
    fi
    rm -f /tmp/sievec.$$
    print_success "The spam filing rule compiles."
fi

chown -R vmail:vmail /var/lib/dovecot/sieve 2>/dev/null || true

if ! systemctl restart dovecot; then
    print_error "Dovecot did not restart with the filing rules. Last 20 lines:"
    journalctl -u dovecot -n 20 --no-pager
    exit 1
fi
print_success "Spam is filed into Junk, and moving mail in or out trains the filter."

# Proof rather than assumption. If the plugins did not load, the learn scripts
# never run and the filter silently never improves, which is invisible until
# months of training turn out not to exist.
if doveconf -n 2>/dev/null | grep -q "sieve_imapsieve"; then
    print_success "Dovecot loaded the training plugins."
else
    print_info "Dovecot did not load sieve_imapsieve, so moving mail will not train it."
    print_action "Check: sudo doveconf -n | grep sieve"
fi

print_dns_records

echo ""
print_success "Rspamd is signing outgoing mail and filtering incoming."
print_status "Next: add_roundcube.sh, for reading mail in a browser."
