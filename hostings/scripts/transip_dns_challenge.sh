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
# Answer a Let's Encrypt DNS-01 challenge through the configured DNS provider.
#
# This exists because port 80 cannot reach this machine. HTTP-01 needs it, and
# the router still sends 80 to the machine being replaced. DNS-01 proves the
# domain instead of the machine, so a certificate can be issued from hardware
# the internet cannot reach at all.
#
# Certbot calls it twice per hostname, through its manual hooks:
#
#   certbot certonly --manual --preferred-challenges dns \
#     --manual-auth-hook    "/path/transip_dns_challenge.sh --add" \
#     --manual-cleanup-hook "/path/transip_dns_challenge.sh --delete" \
#     -d test-progress.example.com
#
# Certbot passes CERTBOT_DOMAIN and CERTBOT_VALIDATION in the environment.
#
# Hooks rather than a plugin: certbot comes from apt here, and every registrar
# plugin is third party and installs with pip, which Ubuntu 24.04 refuses into
# system Python. A hook is two API calls and no packaging problem.
#
# The key itself is installed and proven by add_transip_key.sh. This script only
# ever writes and removes one TXT record, and is not meant to be run by hand.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
#
# Everything goes to stderr, unlike the other scripts here. This one's stdout is
# read by its own caller, so a status line printed to stdout ends up inside the
# variable instead of on the screen.
# That is how a failing hook reported exit 1 and not one word of why.
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1" >&2
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1" >&2
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1" >&2
}

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1" >&2
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1" >&2
}

usage() {
    echo "Usage: $0 --add | --delete" >&2
    echo "" >&2
    echo "  --add     create the _acme-challenge TXT record certbot asked for" >&2
    echo "  --delete  remove it again" >&2
    echo "" >&2
    echo "The key itself is installed and tested by add_transip_key.sh." >&2
    echo "" >&2
    echo "Environment, set by certbot:" >&2
    echo "  CERTBOT_DOMAIN      the hostname being validated" >&2
    echo "  CERTBOT_VALIDATION  the value the TXT record must hold" >&2
    exit 1
}

MODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --add)     MODE="add"; shift ;;
        --delete)  MODE="delete"; shift ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done
[ -z "$MODE" ] && usage

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to read the API key."
    print_action "Please run with: sudo $0 --$MODE"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
# Installed to /usr/local/sbin, REPO_ROOT is /usr: read the pipeline tree's config.
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"

conf_get() {
    local key="$1" default="${2:-}" value
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | head -n1 | tr -d '\r' | cut -d= -f2- | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}


# The credential paths and the account name are the provider's, read by the
# provider. This file used to read four of them and derive the login three
# ways, which is the registrar's setup logic living in a certbot hook.
#
# DNS_PROPAGATION_SECONDS is read the old key's name too, so a machine that
# already carries TRANSIP_PROPAGATION_SECONDS keeps working. How long a zone
# takes to propagate is a property of the provider, but the WAIT is this
# script's: certbot asks the challenge to be visible before it validates.
PROPAGATION_SECONDS="${DNS_PROPAGATION_SECONDS:-${TRANSIP_PROPAGATION_SECONDS:-$(conf_get DNS_PROPAGATION_SECONDS "$(conf_get TRANSIP_PROPAGATION_SECONDS 120)")}}"


# =============================================================================
# Pre-flight. Nothing is signed or sent until everything it needs is present.
# =============================================================================
ERRORS=()

# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

# The account name, the key file and the provider's tools were checked here by
# name. They are dns_preflight's now, so this hook can be pointed at any
# provider certbot's DNS-01 challenge can be written through.
#
# The timeout is exported BEFORE the source, not after it as it used to be:
# certbot runs this hook as root with a tight budget, and a capability set
# after the interface has loaded only works because the provider happens to
# read it at call time. Setting it first does not depend on that.
DNS_TIMEOUT=20
export DNS_TIMEOUT
# shellcheck source=/dev/null
DNS_OPTIONAL=1 . "$(_iface dns.sh)"
if [ "${DNS_READY:-0}" != "1" ]; then
    ERRORS+=("No DNS provider could be loaded. See the message above.")
else
    while IFS= read -r _line; do
        [ -n "$_line" ] && ERRORS+=("$_line")
    done < <(dns_preflight || true)
fi

# Written as full ifs, not `test && ERRORS+=`: under set -e a false test at the
# end of a block ends the script instead of skipping the line.
if [ -z "${CERTBOT_DOMAIN:-}" ]; then
    ERRORS+=("CERTBOT_DOMAIN is not set. This script is meant to be called by certbot.")
fi
if [ "$MODE" = "add" ] && [ -z "${CERTBOT_VALIDATION:-}" ]; then
    ERRORS+=("CERTBOT_VALIDATION is not set. This script is meant to be called by certbot.")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_header "Pre-flight"
    print_error "Cannot continue. Nothing was sent to the DNS provider."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

# =============================================================================
# The provider: dns.sh owns the key, the signing and the verbs.
#
# This was the sixth and last copy of that code. It is sourced at the
# pre-flight now, with the timeout set there, because dns_preflight has to
# answer before anything is checked.
# =============================================================================

# =============================================================================
# Split the hostname into the domain the provider knows and the record name
# under it.
#
# The last two labels are the registered domain. That holds for example.com
# and example.org, and would be wrong for a .co.uk, which nothing here
# uses. Stated rather than detected: a public-suffix list is a dependency this
# does not need today.
# =============================================================================
DOMAIN="$(printf '%s' "$CERTBOT_DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
SUBDOMAIN="${CERTBOT_DOMAIN%.$DOMAIN}"

if [ "$SUBDOMAIN" = "$CERTBOT_DOMAIN" ]; then
    RECORD_NAME="_acme-challenge"
else
    RECORD_NAME="_acme-challenge.$SUBDOMAIN"
fi

# A short TTL because the record lives for about a minute. Any resolver that
# cached it would otherwise keep answering after the cleanup hook removed it.
CHALLENGE_TTL=60

case "$MODE" in
    add)
        print_status "Adding TXT $RECORD_NAME.$DOMAIN"
        dns_add "$DOMAIN" "$RECORD_NAME" TXT "$CERTBOT_VALIDATION" "$CHALLENGE_TTL" || exit 1
        print_success "Record created."

        # Let's Encrypt asks the domain's own nameservers, so ask them too and
        # continue the moment they answer. A fixed sleep is either longer than
        # it needs to be, twice per hostname because of the staging test, or too
        # short on the one day it matters. PROPAGATION_SECONDS is the ceiling
        # now, not the wait.
        if ! command -v dig >/dev/null 2>&1; then
            print_info "dig is not installed, so the record cannot be watched."
            print_info "Waiting the full ${PROPAGATION_SECONDS}s instead. Install it: sudo apt-get install -y dnsutils"
            sleep "$PROPAGATION_SECONDS"
        else
            nameservers="$(dig +short NS "$DOMAIN" | sed 's/\.$//')"
            [ -z "$nameservers" ] && nameservers="8.8.8.8"

            print_status "Waiting for $(printf '%s' "$nameservers" | wc -l) nameserver(s) to serve the record..."
            waited=0
            while [ "$waited" -lt "$PROPAGATION_SECONDS" ]; do
                seen=1
                for ns in $nameservers; do
                    if ! dig +short "@$ns" TXT "$RECORD_NAME.$DOMAIN" 2>/dev/null \
                         | tr -d '"' | grep -qxF "$CERTBOT_VALIDATION"; then
                        seen=0
                        break
                    fi
                done
                if [ "$seen" -eq 1 ]; then
                    print_success "Visible after ${waited}s. Handing back to certbot."
                    break
                fi
                sleep 5
                waited=$((waited + 5))
                redraw "\r\033[K\033[34m🔧 %ss of at most %ss\033[0m" "$waited" "$PROPAGATION_SECONDS" >&2
            done
            redraw "\r\033[K" >&2
            if [ "$seen" -ne 1 ]; then
                print_info "Still not visible after ${PROPAGATION_SECONDS}s. Letting certbot try anyway."
            fi
        fi
        ;;
    delete)
        print_status "Removing TXT $RECORD_NAME.$DOMAIN"
        # Failure here is reported and not fatal: the certificate is already
        # issued by this point, and exiting non-zero would fail a run that
        # actually succeeded. A leftover TXT record is harmless and visible.
        if dns_delete "$DOMAIN" "$RECORD_NAME" TXT "$CERTBOT_VALIDATION" "$CHALLENGE_TTL"; then
            print_success "Record removed."
        else
            print_action "Could not remove $RECORD_NAME.$DOMAIN. Delete it by hand in the control panel."
        fi
        ;;
esac
