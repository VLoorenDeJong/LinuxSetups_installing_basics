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
# Make a place for settings that must not be in git, one file per app row.
#
#   /etc/app-secrets/<row>.env      0600 root:root
#
# WHY THIS EXISTS. apply_app_settings.sh takes KEY=VALUE pairs from the row's
# Options field, and hostings.conf is tracked. A mail password put there is in
# git, in every clone, and in the root-owned pipeline tree. So the row carries
# what is safe to read and this file carries what is not.
#
# The format is the same KEY=VALUE the Options field uses, one per line:
#
#   EmailSettings__Password=...
#   EmailSettings__UserName=...
#
# Double underscore is .NET's own section separator, so the nesting is theirs
# rather than something invented here.
#
# WITHOUT ARGUMENTS THIS SCRIPT ASKS NOTHING AND WRITES NO VALUE. It creates the
# directory, and an inert template whose lines are all commented out, then says
# which file to edit. A template with placeholder values in it would be applied
# and would take the app down, which is exactly how ISPAddressChecker crashed on
# 2026-08-23: EmailToAddress was literally "EmailToAddress".
#
# Safe to re-run: an existing file is never overwritten.
#
#   --fill [row]    Fill in one row's mail settings by asking for them.
#
# WHY --fill EXISTS. Editing the template by hand means knowing which of the
# machine's three SMTP ports takes an unauthenticated connection, and what the
# two addresses are called in .NET's configuration. Only the addresses are
# genuinely the operator's to know, so only the addresses are asked.
#
# NO PASSWORD IS ASKED FOR OR STORED, and that is a property of this machine
# rather than a shortcut. Postfix has mynetworks = 127.0.0.0/8, so port 25 from
# loopback relays with no authentication and no TLS, while 587 and 465 demand
# both. Mail from an app on this box therefore needs no credential at all. The
# connection is loopback only, so there is nothing on the wire to intercept
# without already being root here.
#
# The cost of that choice: pointing MailServer at a remote host later would
# send unencrypted over the network. Anyone doing that must set EnableSsl,
# SMTPPort and a credential themselves, and the written file says so.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

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
SECRETS_DIR="${SECRETS_DIR:-/etc/app-secrets}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    exit 1
fi

app_rows() {
    while IFS='|' read -r type name _rest; do
        type="$(echo "$type" | sed 's/#.*//' | xargs)"
        [ "$type" != "app" ] && continue
        name="$(echo "$name" | xargs)"
        [ -n "$name" ] && echo "$name"
    done < "$SITES_CONF"
}

# Read from the terminal, not stdin: this script is also run from the install
# sequence, which has its own stdin and would answer the prompt itself.
# The answer is the return value, so it is the only thing that may reach
# stdout: the caller captures it with $(...). Everything the reader sees goes
# straight to the terminal, or the question is captured instead of asked and
# the script sits there silently waiting.
ask() {
    local prompt="$1" answer=""
    while [ -z "$answer" ]; do
        printf "\033[33m👉 %s\033[0m\n" "$prompt" > /dev/tty
        printf "   > " > /dev/tty
        read -r answer < /dev/tty
        answer="$(echo "$answer" | xargs)"
        case "$answer" in
            *@*.*) ;;
            "")    ;;
            *)     printf "\033[31m❌ That is not an email address.\033[0m\n" > /dev/tty
                   answer="" ;;
        esac
    done
    echo "$answer"
}

fill_row() {
    local row="$1" target from to

    if [ -z "$row" ]; then
        local rows=() i=1 pick
        while read -r r; do rows+=("$r"); done < <(app_rows)
        [ ${#rows[@]} -eq 0 ] && { print_error "No app rows in $SITES_CONF."; exit 1; }
        print_header "Which application"
        for r in "${rows[@]}"; do printf "   %d) %s\n" "$i" "$r"; i=$((i + 1)); done
        print_action "Type the number of the application to set up mail for."
        printf "   > " > /dev/tty
        read -r pick < /dev/tty
        case "$pick" in
            ''|*[!0-9]*) print_error "Not a number."; exit 1 ;;
        esac
        [ "$pick" -ge 1 ] && [ "$pick" -le ${#rows[@]} ] || { print_error "No such choice."; exit 1; }
        row="${rows[$((pick - 1))]}"
    fi

    if ! app_rows | grep -qx "$row"; then
        print_error "'$row' is not an app row in $SITES_CONF."
        exit 1
    fi

    install -d -m 0700 -o root -g root "$SECRETS_DIR"
    target="${SECRETS_DIR}/${row}.env"

    print_header "Mail settings for $row"
    print_info "The app sends through this machine's own mail server on loopback,"
    print_info "so there is no password to type and none is stored."

    from="$(ask "The address this app sends FROM. A mailbox on this machine, for example admin@$(postconf -h mydomain 2>/dev/null || echo example.com)")"
    to="$(ask "The address its alerts should arrive AT.")"

    local tmp
    tmp="$(mktemp)"
    {
        echo "# Mail settings for '${row}', written by add_app_secrets.sh --fill."
        echo "#"
        echo "# Sent through this machine's postfix on loopback port 25, which"
        echo "# relays without authentication because mynetworks covers 127.0.0.0/8."
        echo "# Nothing here is a secret, and no password is stored."
        echo "#"
        echo "# Pointing MailServer at a remote host means this goes over the"
        echo "# network in clear. Set EnableSsl=true, SMTPPort=587 and a"
        echo "# credential before doing that."
        echo "EmailSettings__EmailFromAddress=${from}"
        echo "EmailSettings__EmailToAddress=${to}"
        echo "EmailSettings__UserName=${from}"
        echo "EmailSettings__MailServer=127.0.0.1"
        echo "EmailSettings__SMTPPort=25"
        echo "EmailSettings__EnableSsl=false"
        echo "EmailSettings__UseDefaultCredentials=true"
    } > "$tmp"
    install -m 0600 -o root -g root "$tmp" "$target"
    rm -f "$tmp"

    print_success "Wrote $target"
    echo ""
    print_info "Nothing is applied until the row is deployed again: the settings are"
    print_info "read on the way in, not by the running service."
    print_action "Deploy it from Jenkins: ${row} -> deploy-live -> Build with Parameters"
}

case "${1:-}" in
    --fill) fill_row "${2:-}"; exit 0 ;;
esac

print_header "Application secrets"
print_status "Directory: $SECRETS_DIR"

install -d -m 0700 -o root -g root "$SECRETS_DIR"

CREATED=0
EXISTING=0
NEEDS_FILLING=()

while IFS='|' read -r type name _rest; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "app" ] && continue
    name="$(echo "$name" | xargs)"
    [ -z "$name" ] && continue

    target="${SECRETS_DIR}/${name}.env"
    if [ -f "$target" ]; then
        # Never overwritten: it holds the only copy of something that is not in
        # git, so a re-run that clobbered it would lose it for good.
        chmod 600 "$target"
        chown root:root "$target"
        EXISTING=$(( EXISTING + 1 ))
        # A file holding only comments has not been filled in yet.
        if ! grep -qE '^[[:space:]]*[^#[:space:]]+=' "$target"; then
            NEEDS_FILLING+=("$target")
        fi
        continue
    fi

    tmp="$(mktemp)"
    {
        echo "# Settings for '${name}' that must not be in git."
        echo "#"
        echo "# Same KEY=VALUE format as the row's Options field, one per line."
        echo "# Double underscore separates .NET configuration sections."
        echo "# Read after the row, so anything here wins."
        echo "#"
        echo "# Uncomment what this app needs and fill in the value. Every line"
        echo "# is commented out on purpose: a placeholder that reaches the app"
        echo "# takes it down, which is what 'EmailToAddress=EmailToAddress' did."
        echo "#"
        echo "#EmailSettings__EmailFromAddress="
        echo "#EmailSettings__EmailToAddress="
        echo "#EmailSettings__MailServer="
        echo "#EmailSettings__UserName="
        echo "#EmailSettings__Password="
    } > "$tmp"
    install -m 0600 -o root -g root "$tmp" "$target"
    rm -f "$tmp"
    CREATED=$(( CREATED + 1 ))
    NEEDS_FILLING+=("$target")
done < "$SITES_CONF"

print_success "Created $CREATED, already there $EXISTING."

if [ ${#NEEDS_FILLING[@]} -gt 0 ]; then
    echo ""
    print_info "These hold nothing yet, so their apps run on whatever the"
    print_info "repository shipped. That is fine for an app that needs no secret."
    for f in "${NEEDS_FILLING[@]}"; do
        print_info "  - $f"
    done
    echo ""
    print_action "Fill one in by answering two questions:  sudo $0 --fill"
    print_action "Or edit it yourself:  sudo nano ${SECRETS_DIR}/<row>.env"
    print_action "Then redeploy that row, and the values are applied on the way in."
fi

print_success "Application secrets directory ready."
