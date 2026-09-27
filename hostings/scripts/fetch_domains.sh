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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# List the domains on the DNS account, so the hosting manager can offer them.
#
# The page cannot do this itself: the API key is systemd-creds encrypted under
# /etc/dns-api and root is the only thing that can decrypt it. So the page calls
# this through sudo with no arguments, exactly like the checker and the
# publisher, and reads the answer out of a file afterwards.
#
# IT ONLY READS. The token it asks for is read_only, so this cannot alter a
# record even if something later goes wrong here. Listing domains is the whole
# job.
#
# A FAILURE KEEPS THE PREVIOUS LIST. TransIP being unreachable must not empty a
# dropdown: a list that is a day stale is useful, and an empty one reads as "you
# own no domains", which is both wrong and alarming. The file is only ever
# replaced by a complete new one.
#
# Output: one domain per line, at /var/lib/hosting-manager/owned-domains
#
# Usage:
#   sudo ./fetch_domains.sh
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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to read the API key."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
OUT="${MANAGER_HOME}/owned-domains"

# The clone when there is one, so the page and this read the same config. Falls
# back to this checkout, which is how it behaves when run by hand from the repo.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
if [ -f "/etc/hostings/hostings.conf" ]; then
    SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
else
    SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
fi

print_header "Domains on the DNS account"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

conf_get() {
    local key="$1" default="${2:-}" value
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" \
             | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}

# Six reads of the provider's own configuration used to sit here: the API URL,
# the credential directory and name, the key file and the account name. Since
# dns_preflight they are the provider's business and nothing in this file
# touches them.

# -----------------------------------------------------------------------------
# Pre-flight. Everything it needs, before the first call.
#
# Each of these is a reason the list cannot be fetched, not a reason the machine
# is broken: DNS management is optional, and a machine without it should say so
# once and leave the existing list alone.
# -----------------------------------------------------------------------------
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

# READ-ONLY IS KEPT, and carrying it across was the whole reason the interface
# grew DNS_READ_ONLY. This script is reachable from a path a web page can
# trigger, so its credential is deliberately incapable of writing; sourcing the
# interface without saying so would hand it a writable token instead.
#
# Exported on its own line, not as `DNS_READ_ONLY=1 . dns.sh`: that form does
# not survive the `.`, and the provider reads it later, when minting.
DNS_READ_ONLY=1
export DNS_READ_ONLY
# shellcheck source=/dev/null
DNS_OPTIONAL=1 . "$(_iface dns.sh)"

# What this needs is the provider's to say. Three checks of DNS_API_URL, the
# account name and the key file lived here, all TransIP's, in a script whose
# job is only "list the zones this account holds".
MISSING=()
if [ "${DNS_READY:-0}" != "1" ]; then
    MISSING+=("No DNS provider could be loaded.")
else
    while IFS= read -r _line; do
        [ -n "$_line" ] && MISSING+=("$_line")
    done < <(dns_preflight || true)
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    print_info "The domain list was not refreshed:"
    for m in "${MISSING[@]}"; do
        print_info "  $m"
    done
    if [ -s "$OUT" ]; then
        print_status "Keeping the list already at $OUT ($(wc -l < "$OUT") domains)."
    fi
    exit 1
fi

# -----------------------------------------------------------------------------
# Through dns.sh, which owns the key, the signing and the verbs.
#
# It is sourced at the pre-flight above, where dns_preflight needs it, with the
# read-only flag set there for the reason given beside it.
# -----------------------------------------------------------------------------

NAMES="$(dns_domains | sort -u)" || NAMES=""
if [ -z "$NAMES" ]; then
    print_error "The domain list could not be read."
    [ -s "$OUT" ] && print_status "The list already at $OUT was left alone."
    exit 1
fi


if [ -z "$NAMES" ]; then
    print_info "The account lists no domains, so nothing was written."
    print_info "That is almost certainly not right: the previous list was kept."
    exit 1
fi

TMP="$(mktemp)"
printf '%s\n' "$NAMES" > "$TMP"

# 0644: the page reads it, and a list of domain names is not a secret. It is the
# same list anyone can read out of public DNS one name at a time.
install -m 0644 -o root -g root "$TMP" "$OUT"
rm -f "$TMP"

print_success "$(printf '%s\n' "$NAMES" | wc -l) domains written to $OUT"
exit 0
