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
# Is this domain still free? Item 106, 2026-09-11.
#
#   check_domain_available.sh <domain>        one JSON line on stdout
#
# A customer asking for a website on a domain nobody owns yet needs somebody to
# order it, and the first question is whether it can be. The configured DNS
# provider answers that, and it is also where the order is placed, so it is the
# only answer that is about the same registry the order goes to.
#
# THE ANSWER IS ADVISORY AND NEVER BLOCKS. The owner raised it himself: an external
# dependency can break. So every failure here is `unknown` with a reason, exit
# 0, and the console shows it as a grey line beside the requester's own tick.
# Nothing is refused because a lookup did not answer.
#
#   {"domain":"x.nl","state":"free","source":"<provider>","checked":1757580000}
#   state: free | taken | unknown
#
# It holds no credential and knows no registrar. dns.sh loads the provider,
# the provider owns the key and the signing, and dns_preflight says what is
# missing: a second way to authenticate to the same account would be a second
# thing to rotate.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }

DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
    echo "Usage: $0 <domain>" >&2
    exit 1
fi

# One JSON line, whatever happened, so the caller never has to tell an error
# from an answer by looking at an exit code.
answer() {
    # The provider names itself. This said "transip" unconditionally, so a run
    # against a different provider file answered correctly and then lied about
    # where the answer came from, which is the one field a reader uses to judge
    # how much to trust it. Found 2026-09-12 by running this script end to end
    # against a second provider for the first time.
    printf '{"domain":"%s","state":"%s","source":"%s","checked":%s,"detail":"%s"}\n' \
        "$DOMAIN" "$1" "${DNS_PROVIDER_NAME:-unknown}" "$(date +%s)" "${2:-}"
    exit 0
}

# A domain name, checked before it reaches a URL. Letters, digits, hyphen and
# dot, at least one dot, nothing that could carry a path or a query with it.
case "$DOMAIN" in
    *[!A-Za-z0-9.-]*|.*|-*|*.) answer unknown "not a domain name" ;;
    *.*) ;;
    *) answer unknown "not a domain name" ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "The API key is root's, so this needs sudo."
    answer unknown "needs root"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"

conf_get() {
    local key="$1" default="$2" value
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
        | head -n1 | tr -d '\r' | cut -d= -f2- | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}

# Four reads of the provider's own credential paths used to sit here and are
# gone with the checks that used them.

# The account name, the key file and the provider's tools were all checked
# here by name, which is TransIP's shape in a script that is supposed to answer
# "is this domain free" whoever is asked. dns_preflight replaces all of it
# below, once the interface is loaded: it cannot run before, and this script
# must answer "unknown" rather than die, so the check sits after the source.

# Through dns.sh, which owns the key, the signing and the verbs.
#
# BOTH CAPABILITIES THIS SCRIPT CHOSE ARE KEPT, and carrying them across is why
# the interface grew them. READ ONLY: this asks a question and must never be
# able to answer one, so a token that leaks cannot order, rename or delete.
# TEN SECONDS: it runs behind a browser drawer, and a lookup that hangs hangs
# the drawer, so the honest answer after ten seconds is "unknown".
DNS_READ_ONLY=1
DNS_TIMEOUT=10
export DNS_READ_ONLY DNS_TIMEOUT
# shellcheck source=/dev/null
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

DNS_OPTIONAL=1 . "$(_iface dns.sh)"
[ "$DNS_READY" = "1" ] || answer unknown "could not reach the DNS provider"

# One reason, not a list: the console shows this as a single grey line beside
# the requester's tick, so the first thing missing is the thing to say.
if ! _reasons="$(dns_preflight)"; then
    answer unknown "$(printf '%s' "$_reasons" | head -n1)"
fi

IFS=$'\t' read -r VERDICT DETAIL <<< "$(dns_domain_available "$DOMAIN")"
answer "${VERDICT:-unknown}" "$DETAIL"
