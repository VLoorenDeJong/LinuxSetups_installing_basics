#!/usr/bin/env bash
# =============================================================================
# DNS, in verbs. The interface; the provider is a config value.
#
#   . "$SCRIPT_DIR/dns.sh"
#   dns_domains                                   every zone, one per line
#   dns_records <zone>                            name<TAB>type<TAB>content<TAB>ttl
#   dns_add     <zone> <name> <type> <content> [ttl]
#   dns_update  <zone> <name> <type> <content> [ttl]   replaces, never adds
#   dns_delete  <zone> <name> <type> <content> [ttl]
#   dns_domain_available <domain>             free, taken or unknown
#   dns_register_url                          where a person registers a domain,
#                                             %s marking where the name goes
#   dns_preflight                             0 if this provider can work, or
#                                             one reason per line and 1
#
# READ-ONLY IS ASKED FOR, NOT ASSUMED. Set DNS_READ_ONLY=1 before sourcing and
# the token minted cannot alter a record, and lasts five minutes rather than
# thirty. A caller that only LISTS should always set it, and one reachable from
# a web page must: a credential that cannot write cannot be made to write.
#
#   export DNS_READ_ONLY=1
#   . "$SCRIPT_DIR/dns.sh"
#
# EXPORT ON ITS OWN LINE, and this is not style. `DNS_READ_ONLY=1 . dns.sh`,
# which this header used to show, sets the variable only for the duration of
# the `.` in non-posix bash. The provider reads it LATER, at the first verb,
# when minting its token, by which time it is unset again: a caller copying
# the old line asked for read-only and got a token that can write. Measured
# 2026-09-12, `inside: [1]` then `after: [unset]`.
#
# The two callers that need it, check_domain_available.sh and
# fetch_domains.sh, already export on a separate line and were never
# affected. The documentation was the bug.
#
# DNS_TOKEN_MINUTES overrides the lifetime either way, and DNS_TIMEOUT bounds
# every call: a caller behind a browser drawer sets it low, because a lookup
# that hangs hangs the drawer.
#
# NO CALLER NAMES A PROVIDER. `DNS_PROVIDER` in hostings.conf names the service
# file; this file resolves and sources it. Swapping registrar is a second
# service file plus one config value, and not one line in any caller.
#
# WHY A SECOND FILE, when dns_provider_transip.sh already exposes verbs. Because
# every caller resolved DNS_PROVIDER ITSELF, so the resolution, the missing-file
# message and the error handling were each about to be copied seven times: the
# exact shape principle 2b exists to stop, one layer up.
#
# CHANGED AND DROPPED ARE DIFFERENT QUESTIONS.
#
#   changed   a second service file exposing these verbs. Nothing else moves
#   dropped   sourcing fails loudly HERE, at the top of a run, instead of
#             "command not found" somewhere in the middle of writing records.
#             A caller that can live without DNS sources with DNS_OPTIONAL=1
#             and tests $DNS_READY
#
# THE VERBS ARE CHECKED AT SOURCE TIME. In bash an interface is a promise, not
# a contract: a service file missing dns_delete is a runtime error halfway
# through a prune. Checking the names costs nothing and turns that into a
# refusal before anything is written.
#
# dns_records is NORMALISED and dns_list is not. dns_list hands back whatever
# the provider's API returned, which is provider knowledge leaking into the
# caller; it stays only because add_dns_records.sh's prune path already reads
# it. New callers use dns_records.
# =============================================================================

print_error()  { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_action() { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }

DNS_READY=0
DNS_PROVIDER_FILE=""

_dns_conf_get() {
    local v
    [ -n "${SITES_CONF:-}" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

# The verbs a service file must provide. A name added here is a name every
# provider has to answer to, so it is not a list to grow casually.
# dns_preflight is required like the rest: a provider that cannot say what it
# needs leaves every caller guessing, which is the six TransIP-shaped
# pre-flights this verb exists to delete.
DNS_REQUIRED_VERBS="dns_domains dns_records dns_add dns_update dns_delete dns_domain_available dns_register_url dns_preflight"

_dns_load() {
    local dir name cand
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # The environment wins over the config, as SITES_CONF does everywhere else:
    # it is how a provider is tried once without editing the file every machine
    # reads.
    name="${DNS_PROVIDER:-$(_dns_conf_get DNS_PROVIDER dns_provider_transip.sh)}"
    # Sourced as root from a value the console can write: a bare file name only.
    if ! [[ "$name" =~ ^dns_provider_[a-z0-9_]+\.sh$ ]]; then
        print_error "DNS_PROVIDER '$name' is not a dns_provider_<name>.sh file name."
        return 1
    fi

    for cand in "$dir/$name" \
                "/usr/local/lib/linuxbasics/hostings/scripts/$name"; do
        [ -f "$cand" ] && { DNS_PROVIDER_FILE="$cand"; break; }
    done
    if [ -z "$DNS_PROVIDER_FILE" ]; then
        print_error "No DNS provider file called '$name' beside dns.sh or in the pipeline tree."
        print_action "Set DNS_PROVIDER in ${SITES_CONF:-hostings.conf}, or put the file there."
        return 1
    fi

    # shellcheck source=/dev/null
    . "$DNS_PROVIDER_FILE" || {
        print_error "$DNS_PROVIDER_FILE could not be sourced."
        return 1
    }

    local missing=""
    for v in $DNS_REQUIRED_VERBS; do
        declare -F "$v" >/dev/null 2>&1 || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        print_error "$DNS_PROVIDER_FILE does not provide:$missing"
        print_action "A DNS provider file must expose: $DNS_REQUIRED_VERBS"
        return 1
    fi

    DNS_READY=1
}

if ! _dns_load; then
    # DNS_OPTIONAL is for a caller that can do its job without DNS and wants to
    # say so out loud rather than die. Everything else stops here, which is the
    # point: a run that cannot reach DNS must not get as far as half-writing a
    # zone.
    if [ "${DNS_OPTIONAL:-0}" = "1" ]; then
        print_action "Carrying on without DNS. Anything that needed it is skipped, not guessed."
    else
        return 1 2>/dev/null || exit 1
    fi
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            printf 'provider: %s\n' "${DNS_PROVIDER_FILE:-none}"
            printf 'ready:    %s\n' "$DNS_READY"
            printf 'verbs:    %s\n' "$DNS_REQUIRED_VERBS"
            [ "$DNS_READY" = "1" ] || exit 1
            if out="$(dns_domains 2>/dev/null)" && [ -n "$out" ]; then
                printf 'domains:  %s\n' "$(printf '%s' "$out" | tr '\n' ' ')"
            else
                printf 'domains:  the provider answered nothing\n'; exit 1
            fi
            ;;
        *)
            printf 'Source this file. %s --check names the provider and lists the zones.\n' "$0" >&2
            exit 1
            ;;
    esac
fi
