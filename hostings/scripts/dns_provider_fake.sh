#!/usr/bin/env bash
# =============================================================================
# A DNS provider that talks to a TEXT FILE. It is a test double, not a service.
#
# WHY IT EXISTS. dns.sh says swapping registrar is "a second service file plus
# one config value, and not one line in any caller". Until this file, there was
# only ever ONE provider, so that sentence had never been tested: a contract
# with a single implementation is a description of that implementation.
#
# This is the second implementation, and its whole job is to be the OTHER one.
# It answers the same six verbs against a flat file, so the swap can be proved
# by running rather than by reading.
#
#   DNS_PROVIDER=dns_provider_fake.sh . "$SCRIPT_DIR/dns.sh"
#
# THE STORE IS ONE TAB-SEPARATED FILE, default /tmp/dns-fake/zone.tsv, and
# DNS_FAKE_STORE moves it. One record per line:
#
#   zone<TAB>name<TAB>type<TAB>content<TAB>ttl
#
# Zones come from DNS_FAKE_DOMAINS, default "example.test example.invalid".
# Both are RFC 2606 / RFC 6761 reserved names that can never be registered, so
# a record written here names nothing real even by accident.
#
# WHAT IT DELIBERATELY DOES NOT DO, so nobody mistakes it for a provider:
#
#   no network       no curl, no host, no dig. Nothing leaves the machine
#   no credential    no key, no token, no login. dns_auth is a no-op that
#                    succeeds, because there is nothing to authenticate to
#   no propagation   a write is visible to the next read instantly, which a
#                    real zone never is. A caller that needs to wait for
#                    propagation is NOT exercised by this file
#   no rate limit    and no per-zone record cap, so a caller that would be
#                    refused by a registrar passes here
#   no validation    content is stored as given. A malformed SPF string, a
#                    CNAME at an apex and a TTL of 1 are all accepted
#
# So a green run against this file proves the INTERFACE holds. It proves
# nothing about whether the records would be accepted by a registrar.
#
# MUST NEVER BE NAMED BY DNS_PROVIDER ON A LIVE MACHINE. A machine configured
# this way believes every record it asked for was written, reports success, and
# has changed no zone anywhere: certificates fail their challenge, mail loses
# its DKIM record, and every check in the fleet says the work was done. Use it
# from the environment for one run, never from hostings.conf.
#
# SOURCED, NOT RUN, like every provider file. `bash dns_provider_fake.sh --check`
# says where the store is and how many records it holds.
# =============================================================================

# --- Inline utility functions, copied per principle 2 ------------------------
# A caller that already defines them keeps its own.
if ! declare -F print_status >/dev/null 2>&1; then
    print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
    print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
    print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
    print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
    print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
fi

DNS_PROVIDER_NAME="fake"

DNS_FAKE_STORE="${DNS_FAKE_STORE:-/tmp/dns-fake/zone.tsv}"
DNS_FAKE_DOMAINS="${DNS_FAKE_DOMAINS:-example.test example.invalid}"

# SAY SO ON EVERY RUN. A test double that is quiet is a test double somebody
# leaves in place.
print_info "DNS provider is the FAKE one. Nothing reaches a registrar; the store is $DNS_FAKE_STORE."

_dns_fake_init() {
    local dir
    dir="$(dirname "$DNS_FAKE_STORE")"
    [ -d "$dir" ] || mkdir -p "$dir" || return 1
    [ -f "$DNS_FAKE_STORE" ] || : > "$DNS_FAKE_STORE"
}

# READ-ONLY IS HONOURED, because that is a capability the interface promises and
# a double that ignores it would let a read-only caller pass a test it should
# fail. Real providers enforce it in the token; here it is enforced in the verb.
_dns_fake_refuse_if_read_only() {
    if [ "${DNS_READ_ONLY:-0}" = "1" ]; then
        print_error "This run asked for a read-only credential, so $1 is refused."
        return 1
    fi
    return 0
}

# There is nothing to authenticate to. It exists because the TransIP file has it
# and a caller may call it.
dns_auth() { return 0; }

# This provider needs no URL, no account and no key: that is the whole point of
# it, and it is what proves a caller's pre-flight is no longer TransIP-shaped.
# All it can fail on is a store it cannot write.
# A reserved name, so a click in a test can never reach a real shop.
dns_register_url() {
    printf '%s' 'https://registrar.invalid/register/%s'
}

dns_preflight() {
    local dir
    dir="$(dirname "$DNS_FAKE_STORE")"
    mkdir -p "$dir" 2>/dev/null || { printf 'Cannot create the fake store directory %s\n' "$dir"; return 1; }
    [ -w "$dir" ] || { printf 'The fake store directory %s is not writable\n' "$dir"; return 1; }
    return 0
}

# -----------------------------------------------------------------------------
# The verbs.
# -----------------------------------------------------------------------------

dns_domains() {
    _dns_fake_init || return 1
    printf '%s\n' $DNS_FAKE_DOMAINS
}

# NORMALISED: name<TAB>type<TAB>content<TAB>ttl, which is what dns.sh promises.
dns_records() {
    local domain="${1:-}"
    [ -n "$domain" ] || { print_error "dns_records needs a domain."; return 1; }
    _dns_fake_init || return 1
    awk -F'\t' -v z="$domain" 'BEGIN{OFS="\t"} $1==z {print $2,$3,$4,$5}' "$DNS_FAKE_STORE"
}

# RAW, the shape dns_list has for TransIP: the provider's own JSON. Three
# callers still read dnsEntries, so a double that omitted this would make them
# look portable when they are not.
dns_list() {
    local domain="${1:-}"
    [ -n "$domain" ] || { print_error "dns_list needs a domain."; return 1; }
    _dns_fake_init || return 1
    awk -F'\t' -v z="$domain" '
        BEGIN { printf "{\"dnsEntries\":[" ; n=0 }
        $1==z {
            if (n++) printf ","
            printf "{\"name\":\"%s\",\"expire\":%s,\"type\":\"%s\",\"content\":\"%s\"}", $2, ($5==""?300:$5), $3, $4
        }
        END { print "]}" }
    ' "$DNS_FAKE_STORE"
}

dns_add() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}"
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_add needs domain, name, type and content."
        return 1
    fi
    _dns_fake_refuse_if_read_only dns_add || return 1
    _dns_fake_init || return 1
    printf '%s\t%s\t%s\t%s\t%s\n' "$domain" "$name" "$type" "$content" "$ttl" >> "$DNS_FAKE_STORE"
}

# REPLACES the records of this name and type, never adds a second one. That is
# the whole reason the verb is separate from dns_add: an apex A record with two
# values round-robins visitors between a live machine and a dead one.
dns_update() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}" tmp
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_update needs domain, name, type and content."
        return 1
    fi
    _dns_fake_refuse_if_read_only dns_update || return 1
    _dns_fake_init || return 1
    tmp="$(mktemp)" || return 1
    awk -F'\t' -v z="$domain" -v n="$name" -v t="$type" \
        '!($1==z && $2==n && $3==t)' "$DNS_FAKE_STORE" > "$tmp" || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$domain" "$name" "$type" "$content" "$ttl" >> "$tmp"
    mv "$tmp" "$DNS_FAKE_STORE"
}

# All four fields identify the record, as TransIP's DELETE does: a wrong TTL
# removes nothing. Pass back what a read returned, never values you rebuilt.
dns_delete() {
    local domain="${1:-}" name="${2:-}" type="${3:-}" content="${4:-}" ttl="${5:-300}" tmp before after
    if [ -z "$domain" ] || [ -z "$name" ] || [ -z "$type" ] || [ -z "$content" ]; then
        print_error "dns_delete needs domain, name, type and content."
        return 1
    fi
    _dns_fake_refuse_if_read_only dns_delete || return 1
    _dns_fake_init || return 1
    before="$(wc -l < "$DNS_FAKE_STORE")"
    tmp="$(mktemp)" || return 1
    awk -F'\t' -v z="$domain" -v n="$name" -v t="$type" -v c="$content" -v e="$ttl" \
        '!($1==z && $2==n && $3==t && $4==c && $5==e)' "$DNS_FAKE_STORE" > "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$DNS_FAKE_STORE"
    after="$(wc -l < "$DNS_FAKE_STORE")"
    [ "$before" -gt "$after" ]
}

# "<verdict><TAB><the provider's own word>", verdict one of free, taken or
# unknown. A name whose zone this double already serves is taken; anything
# ending .test or .invalid is free; everything else is unknown, because a file
# on this machine genuinely does not know.
#
# It never fails the caller, which is the interface's rule for this verb.
dns_domain_available() {
    local domain="${1:-}" d
    [ -n "$domain" ] || { printf 'unknown\tnot a domain name'; return 0; }
    for d in $DNS_FAKE_DOMAINS; do
        [ "$domain" = "$d" ] && { printf 'taken\tinyouraccount'; return 0; }
    done
    case "$domain" in
        *.test|*.invalid) printf 'free\t' ;;
        *)                printf 'unknown\tthe fake provider only knows reserved names' ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# --check: where the store is and what is in it. Run directly, never when sourced.
# -----------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            _dns_fake_init || { print_error "Could not create $DNS_FAKE_STORE"; exit 1; }
            print_status "Provider:  $DNS_PROVIDER_NAME (a test double, not a registrar)"
            print_status "Store:     $DNS_FAKE_STORE"
            print_status "Zones:     $DNS_FAKE_DOMAINS"
            print_status "Records:   $(wc -l < "$DNS_FAKE_STORE")"
            print_success "No credential is needed, because nothing is contacted."
            ;;
        *)
            print_info "This file is sourced, not run. It answers the dns.sh verbs from a text file."
            print_action "To see the store: bash $0 --check"
            ;;
    esac
fi
