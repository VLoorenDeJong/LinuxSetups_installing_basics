#!/usr/bin/env bash
# =============================================================================
# WHAT IS THIS MACHINE'S PUBLIC ADDRESS. The interface; the providers are a
# config value.
#
# Sourced, never run for effect:
#
#   . "$SCRIPT_DIR/public_ip.sh"
#   ip="$(public_ip4)"          one address, or nothing and exit 1
#   ip="$(public_ip4_checked)"  the address, refusing on a contradiction
#   ip6="$(public_ip6)"
#
# WHY IT EXISTS. Measured 2026-09-12: three scripts asked three different sets
# of hosts with four different policies.
#
#   add_site_certificates.sh:516  two hosts, first answer wins
#   update_dns_apex.sh:205        two hosts, and it compares them
#   go_live.sh:178                one host, no fallback, no -4
#
# So the redundancy already existed by accident and the POLICY lived nowhere.
# Nobody could change it in one place, which is the same fault as the seven
# copies of the TransIP key reader that principle 2b was written for.
#
# CHANGED AND DROPPED ARE DIFFERENT QUESTIONS, and this file answers both.
#
#   changed   PUBLIC_IP_PROVIDERS names the hosts. A dead provider is a config
#             edit, not a code change, and no caller names a host
#   dropped   every provider unreachable prints nothing and returns 1. The
#             CALLER decides what that means, because the right answer differs:
#             go_live must refuse, a display line may just say unknown
#
# It never guesses and never returns a cached value. An address this machine
# cannot confirm is worse than no address: it goes into DNS and into a
# certificate request.
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

_PUBIP_CONF="${SITES_CONF:-}"
_pubip_conf_get() {
    local v
    [ -n "$_PUBIP_CONF" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$_PUBIP_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

# The ENVIRONMENT wins over the config, as SITES_CONF does everywhere else:
# it is how a provider list is tried once without editing the file every
# machine reads. Found 2026-09-12 by testing the dropped path, which could not
# be reached at all while the config value overwrote the variable.
#
# Comma separated, asked in order. The defaults are the three hosts the scripts
# already used, so this file changes nothing about who is asked.
PUBLIC_IP_PROVIDERS="${PUBLIC_IP_PROVIDERS:-$(_pubip_conf_get PUBLIC_IP_PROVIDERS 'https://api.ipify.org,https://ifconfig.me/ip,https://ifconfig.co')}"
PUBLIC_IP6_PROVIDERS="${PUBLIC_IP6_PROVIDERS:-$(_pubip_conf_get PUBLIC_IP6_PROVIDERS 'https://api64.ipify.org')}"
PUBLIC_IP_TIMEOUT="${PUBLIC_IP_TIMEOUT:-$(_pubip_conf_get PUBLIC_IP_TIMEOUT 10)}"

_is_ip4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
_is_ip6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]]; }

# -4 and -6 are not optional. Without them curl answers over whichever family
# connects first, so "the IPv4 address" came back as an IPv6 one on a machine
# with both, which is how a wrong A record gets written.
_ask() {
    local family="$1" url="$2" out
    out="$(curl -fsS "$family" --max-time "$PUBLIC_IP_TIMEOUT" "$url" 2>/dev/null || true)"
    printf '%s' "${out//[$'\r\n\t ']/}"
}

# The first provider that answers something that looks like an address.
public_ip4() {
    local url got
    IFS=',' read -r -a _urls <<< "$PUBLIC_IP_PROVIDERS"
    for url in "${_urls[@]}"; do
        [ -n "$url" ] || continue
        got="$(_ask -4 "$url")"
        _is_ip4 "$got" && { printf '%s' "$got"; return 0; }
    done
    return 1
}

public_ip6() {
    local url got
    IFS=',' read -r -a _urls <<< "$PUBLIC_IP6_PROVIDERS"
    for url in "${_urls[@]}"; do
        [ -n "$url" ] || continue
        got="$(_ask -6 "$url")"
        _is_ip6 "$got" && { printf '%s' "$got"; return 0; }
    done
    return 1
}

# THE ADDRESS, REFUSING IF THE PROVIDERS CONTRADICT EACH OTHER. For the callers
# that WRITE the answer somewhere durable: a provider having a bad day puts a
# wrong address into DNS, and a wrong apex record is not noticed until
# something stops resolving.
#
# One provider answering is ENOUGH. Requiring two would refuse on the day one
# is down, which is the opposite of what a caller writing DNS wants: it wants
# to be stopped by a CONTRADICTION, not by a quiet network.
#
#   0   every provider that answered said the same thing, printed
#   1   nobody answered, nothing printed
#   3   they disagree. Nothing printed, both values named on stderr
#
# update_dns_apex.sh has always done this by hand. The policy lives here now,
# and 3 is a separate code because "nobody answered" and "they disagree" need
# different words from the caller.
public_ip4_checked() {
    local url got first="" other=""
    IFS=',' read -r -a _urls <<< "$PUBLIC_IP_PROVIDERS"
    for url in "${_urls[@]}"; do
        [ -n "$url" ] || continue
        got="$(_ask -4 "$url")"
        _is_ip4 "$got" || continue
        if [ -z "$first" ]; then
            first="$got"
        elif [ "$got" != "$first" ]; then
            other="$got"
            break
        fi
    done
    if [ -n "$other" ]; then
        print_error "Two services disagree about this address: $first and $other"
        return 3
    fi
    [ -n "$first" ] || return 1
    printf '%s' "$first"
}
# Run directly to see what the providers say, which is the one thing worth
# having when a certificate request has just been refused for the wrong address.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            printf 'providers v4: %s\n' "$PUBLIC_IP_PROVIDERS"
            printf 'providers v6: %s\n' "$PUBLIC_IP6_PROVIDERS"
            if v="$(public_ip4)"; then printf 'v4:        %s\n' "$v"; else printf 'v4:        no provider answered\n'; fi
            v="$(public_ip4_checked)"; rc=$?
            case "$rc" in
                0) printf 'v4 checked: %s\n' "$v" ;;
                3) printf 'v4 checked: the providers contradict each other, see above\n' ;;
                *) printf 'v4 checked: no provider answered\n' ;;
            esac
            if v="$(public_ip6)"; then printf 'v6:        %s\n' "$v"; else printf 'v6:        no provider answered\n'; fi
            ;;
        *)
            printf 'Source this file. %s --check asks every provider and prints what each says.\n' "$0" >&2
            exit 1
            ;;
    esac
fi
