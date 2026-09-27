#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Read and write one app row's mail addresses, for the console.
#
#   app_mail_settings.sh --read  <row>              JSON on stdout
#   app_mail_settings.sh --write <row> <from> <to>  writes the file
#
# The file is /etc/app-secrets/<row>.env, 0600 root, which the page
# runs as hosting-manager and cannot touch. This is the whole reason the script exists:
# root does the writing, and what it will write is bounded here rather than by
# the page.
#
# WHAT IS BOUNDED, and it is the security of the arrangement:
#
#   - the row must be an `app` row in the PUBLISHED config, not one the caller
#     invented, so no path can be steered outside the secrets directory;
#   - both addresses must look like addresses, so nothing else can be smuggled
#     into the file;
#   - the keys written are fixed here. The caller chooses two values, never a
#     key, so the page cannot set a connection string or a credential.
#
# NO PASSWORD IS INVOLVED, and that is a fact about this machine rather than an
# omission. Postfix has mynetworks = 127.0.0.0/8, so port 25 from loopback
# relays with no authentication and no TLS, while 587 and 465 demand both. An
# app on this box therefore reaches its own mail server with no credential, and
# the connection never leaves loopback.
#
# The cost, stated because it is what would bite: this writes MailServer as
# 127.0.0.1 every time. Sending through an outside provider needs a password
# and TLS, and neither this script nor the console will do it. Edit the file by
# hand for that, and it will be preserved until the console writes again.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# Yellow means "this needs you", never "warning".
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

usage() {
    echo "Usage:"
    echo "  $0 --read  <row>"
    echo "  $0 --write <row> <from-address> <to-address>"
}

MODE=""
case "${1:-}" in
    --read)  MODE="read" ;;
    --write) MODE="write" ;;
    *)       usage; exit 1 ;;
esac

ROW="${2:-}"
if [ -z "$ROW" ]; then
    usage
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
CLONE="${MANAGER_HOME}/config-repo"
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
SECRETS_DIR="${SECRETS_DIR:-/etc/app-secrets}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "No config at $SITES_CONF, so the row could not be checked."
    exit 1
fi

# Checked against the published config rather than against whatever files
# happen to be in the secrets directory. A row name that is not there cannot
# name a file, and the name is what builds the path.
if ! awk -F'|' -v n="$ROW" '
        /^[[:space:]]*#/ { next }
        NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
                 gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                 if ($1 == "app" && $2 == n) found = 1 }
        END { exit !found }' "$SITES_CONF"; then
    print_error "'$ROW' is not an app row in the published config."
    exit 1
fi

TARGET="${SECRETS_DIR}/${ROW}.env"

# The value of one KEY= line, or empty. Commented lines are not values: the
# template ships every line commented out precisely so it applies nothing.
value_of() {
    local key="$1"
    [ -f "$TARGET" ] || return 0
    sed -n "s/^[[:space:]]*${key}=//p" "$TARGET" | tail -n 1
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# What the deployed app is actually running with.
#
# The secrets file is only the last of three layers: the repository ships
# appsettings.json, the row's Options field overrides it, and this file
# overrides both. Reading only this file would show an empty box for an app
# that is running perfectly well on a value set somewhere else, and the first
# save would then blank it.
#
# The deployed file is read, never written. It is the merged result, so it is
# the truth about what is running, and it is regenerated by every deploy.
deployed_value_of() {
    local key="$1" app_root row_path dir file val
    app_root="$(sed -n 's/^[[:space:]]*APP_ROOT_LIVE[[:space:]]*=//p' "$SITES_CONF" | head -n 1 | sed 's/#.*//' | xargs)"
    [ -z "$app_root" ] && return 0

    row_path="$(awk -F'|' -v n="$ROW" '
        /^[[:space:]]*#/ { next }
        NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                 if ($2 == n) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4; exit } }' "$SITES_CONF")"
    [ -z "$row_path" ] && return 0

    dir="$(dirname "${app_root%/}/${row_path#/}")"
    file="${dir}/appsettings.json"
    [ -f "$file" ] || return 0

    # Tolerant on purpose: appsettings.json here is JSONC, and a real parser
    # refusing a comment is how a deploy went down on 2026-08-23.
    val="$(sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n 1)"

    # The repository ships the key's own name as its value. That is a
    # placeholder, not a setting, and showing it in the box would let somebody
    # save it, which is exactly what took the app down.
    [ "$val" = "$key" ] && return 0
    echo "$val"
}

# The file wins where it has a value, because that is the layer the console
# owns. Below it, whatever the app is actually running with.
effective() {
    local key="$1" v
    v="$(value_of "$key")"
    [ -n "$v" ] && { echo "$v"; return 0; }
    deployed_value_of "${key#EmailSettings__}"
}

if [ "$MODE" = "read" ]; then
    FROM_NOW="$(effective EmailSettings__EmailFromAddress)"
    TO_NOW="$(effective EmailSettings__EmailToAddress)"
    printf '{"row":"%s","from":"%s","to":"%s","configured":%s,"owned":%s}\n' \
        "$(json_escape "$ROW")" \
        "$(json_escape "$FROM_NOW")" \
        "$(json_escape "$TO_NOW")" \
        "$([ -n "$TO_NOW" ] && echo true || echo false)" \
        "$([ -n "$(value_of EmailSettings__EmailToAddress)" ] && echo true || echo false)"
    exit 0
fi

FROM="${3:-}"
TO="${4:-}"

for pair in "sends from:$FROM" "alerts to:$TO"; do
    label="${pair%%:*}"
    addr="${pair#*:}"
    case "$addr" in
        *@*.*) ;;
        *) print_error "The '$label' address is not an email address: '${addr}'"
           exit 1 ;;
    esac
    # Anything that could break out of one KEY=VALUE line, or out of the shell
    # that reads it later. The address grammar allows none of these.
    case "$addr" in
        *[\ \'\"\$\`\\]*|*'
'*) print_error "The '$label' address contains a character an address cannot hold."
    exit 1 ;;
    esac
done

install -d -m 0700 -o root -g root "$SECRETS_DIR"

TMP="$(mktemp)"
{
    echo "# Mail settings for '${ROW}', written by the hosting console."
    echo "#"
    echo "# Sent through this machine's postfix on loopback port 25, which"
    echo "# relays without authentication because mynetworks covers 127.0.0.0/8."
    echo "# Nothing here is a secret and no password is stored."
    echo "#"
    echo "# Editing this by hand is fine, but the console overwrites the whole"
    echo "# file when it saves. Anything added below is lost at the next save."
    echo "EmailSettings__EmailFromAddress=${FROM}"
    echo "EmailSettings__EmailToAddress=${TO}"
    echo "EmailSettings__UserName=${FROM}"
    echo "EmailSettings__MailServer=127.0.0.1"
    echo "EmailSettings__SMTPPort=25"
    echo "EmailSettings__EnableSsl=false"
    echo "EmailSettings__UseDefaultCredentials=true"
} > "$TMP"
install -m 0600 -o root -g root "$TMP" "$TARGET"
rm -f "$TMP"

print_success "Wrote $TARGET"
print_info "Applied on the next deploy of '$ROW', not to the running service."
