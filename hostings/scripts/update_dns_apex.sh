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
# Point every domain's apex record at this household's current address.
#
# This is the other half of add_dns_records.sh, and the split is deliberate.
# That script owns the NAMES: one CNAME per hostname, pointing at its apex. This
# one owns the ADDRESS: three A records and three AAAA records, one pair per
# domain, and nothing else on the machine writes them.
#
# Two writers for one record is how every site ends up pointing at the wrong
# place, so there is exactly one, and it is this.
#
# WHY IT IS ONE WRITE PER DOMAIN AND NOT ONE PER HOSTNAME
#
# Everything else is a CNAME pointing here, so an address change is six writes
# whatever the machine serves. A run that fails halfway leaves some names
# working and some not, and six is small enough that a retry is trivial.
#
# ONLY THE LIVE MACHINE MAY RUN IT
#
# MACHINE_IS_LIVE = no refuses before anything is signed. A replacement built
# beside the live one runs the same scripts from the same branch, and two
# machines fighting over the address record is the worst failure available here.
#
# THE AAAA RECORD IS THIS MACHINE, NOT THE ROUTER
#
# IPv4 goes through the router, which forwards to whichever machine is chosen.
# IPv6 does not: the address belongs to the machine itself. So an AAAA record
# written from a test machine sends every IPv6 visitor straight past the router
# to hardware that is not live, while IPv4 visitors reach the real one and the
# same site answers differently depending on the visitor's connection.
#
# The live check above is what prevents that, and it is the reason it refuses
# rather than warns. Decided 2026-08-08: IPv6 IS published, after the swap.
#
# WHO CALLS IT
#
# The Jenkins `apex` job, triggered by ISPAddressChecker when it sees a
# genuinely new address. Not on connectivity flapping: a line that drops and
# returns with the same address must write nothing, or a bad evening becomes
# fifty DNS writes.
#
# Usage:
#   sudo bash update_dns_apex.sh              detect the address, write if changed
#   sudo bash update_dns_apex.sh --check      report only, write nothing
#   sudo bash update_dns_apex.sh --ipv4 <ip>  use this address instead of detecting
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

MODE="apply"
WANT_IP4=""
WANT_IP6=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check"; shift ;;
        --ipv4)  WANT_IP4="$2"; shift 2 ;;
        --ipv6)  WANT_IP6="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--check] [--ipv4 <address>] [--ipv6 <address>]" >&2
            exit 1
            ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to read the API key."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

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

is_yes() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs)" in
        y|yes|true|1) return 0 ;;
        *)            return 1 ;;
    esac
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
DNS_TTL="$(conf_get DNS_TTL 300)"
MACHINE_IS_LIVE="$(conf_get MACHINE_IS_LIVE no)"

# The API URL, the credential directory, the key file, the credential name and
# the account name were all read here and, since dns_preflight, used by nothing
# in this file. The provider reads its own. Six dead reads of somebody else's
# configuration are how a script keeps looking like it talks to a registrar
# long after it stopped.

DOMAINS=()
_raw="$(conf_get DNS_DOMAINS "")"
if [ -n "$_raw" ]; then
    IFS=',' read -r -a _d <<< "$_raw"
    for d in "${_d[@]}"; do
        d="$(printf '%s' "$d" | xargs)"
        [ -n "$d" ] && DOMAINS+=("$d")
    done
fi
[ ${#DOMAINS[@]} -eq 0 ] && [ -n "$BASE_DOMAIN" ] && DOMAINS=("$BASE_DOMAIN")

print_header "Apex records"
print_status "Domains: ${DOMAINS[*]:-none}"
print_status "Mode:    $MODE"

# =============================================================================
# Pre-flight
# =============================================================================
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
#
# Defined HERE, above the pre-flight, because dns.sh is sourced there now. It
# used to sit further down beside the public_ip.sh source, and moving only the
# source up left `_iface: command not found` on a machine but not on a syntax
# check. Same shape as published_txt earlier today: a definition that has to be
# above ALL of its callers, not just the one you were looking at.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

ERRORS=()

[ ${#DOMAINS[@]} -eq 0 ] && ERRORS+=("No DNS_DOMAINS and no BASE_DOMAIN in $SITES_CONF")

# What the DNS provider needs is the provider's to say. This used to check
# DNS_API_URL, the account name, the key file and four tools here, all of them
# TransIP's requirements in a script that names no registrar anywhere else.
# dns.sh is sourced above the pre-flight now, with DNS_OPTIONAL=1, so a missing
# provider is one of these lines rather than an exit before the list is shown.
# shellcheck source=/dev/null
DNS_OPTIONAL=1 . "$(_iface dns.sh)"
if [ "${DNS_READY:-0}" != "1" ]; then
    ERRORS+=("No DNS provider could be loaded. See the message above.")
else
    while IFS= read -r _line; do
        [ -n "$_line" ] && ERRORS+=("$_line")
    done < <(dns_preflight || true)
fi

# The refusal that matters most, and it is checked before anything is signed.
if ! is_yes "$MACHINE_IS_LIVE" && [ "$MODE" != "check" ]; then
    print_error "MACHINE_IS_LIVE = no, so this machine does not own the address record."
    print_info "Refusing before anything was signed. Two machines writing this record"
    print_info "is how every site ends up pointing at the wrong one."
    print_action "Flip it after the drive swap, or use --check to see what it would do."
    exit 1
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

# =============================================================================
# What address are we actually on
#
# Asked of more than one service. A single provider having a bad afternoon must
# not be able to point every domain at nothing, so a disagreement stops the run
# rather than picking one.
# =============================================================================
# Through public_ip.sh, which owns the provider list and the contradiction
# rule now. This script named two v4 hosts and one v6 host of its own, and two
# other scripts named different ones.
#
# Exit code 3 is the disagreement, kept as its own case: "nobody answered" and
# "they contradict each other" need different words, and only the second is a
# reason to write nothing and try again in a minute.
. "$(_iface public_ip.sh)"

detect_ipv4() {
    local out rc
    out="$(public_ip4_checked)"; rc=$?
    if [ "$rc" = "3" ]; then
        print_info "Nothing was written. Try again in a minute."
        exit 1
    fi
    printf '%s' "$out"
}

IP4="${WANT_IP4:-$(detect_ipv4)}"
IP6="${WANT_IP6:-$(public_ip6 || true)}"

if [ -z "$IP4" ]; then
    print_error "Could not work out this machine's public IPv4 address."
    print_info "Nothing was written."
    exit 1
fi

print_status "IPv4:    $IP4"
print_status "IPv6:    ${IP6:-none}"

# Said on a check run, because a check on a test machine is where the AAAA
# records look like something missing rather than something deliberate.
if [ -n "$IP6" ] && ! is_yes "$MACHINE_IS_LIVE"; then
    print_info "That IPv6 address is THIS machine, not the router."
    print_info "Publishing it from a machine that is not live would send IPv6"
    print_info "visitors here while IPv4 visitors reach the live one."
fi

# =============================================================================
# The API: it does not talk to one. dns.sh does.
#
# This script carried its own get_token, its own signature and its own api(),
# one of six copies of that code across the fleet and six places to leak a key.
# public_ip.sh was already sourced above; the DNS half is sourced at the
# pre-flight, because dns_preflight has to run before anything is checked.
# =============================================================================

# =============================================================================
# Compare, then write only what differs
#
# A record already holding the right address is left alone. This runs when the
# address changed, and rewriting five correct records to fix one is how a
# partial failure becomes five broken domains instead of one.
# =============================================================================
TO_WRITE=()
UNCHANGED=0

print_header "What would change"

for dom in "${DOMAINS[@]}"; do
    # dns_records, not dns_list: the four normalised fields dns.sh promises,
    # rather than the provider's own JSON dug out with jq.
    current="$(dns_records "$dom")" || {
        print_error "Could not read the records for $dom."
        exit 1
    }

    for pair in "A:$IP4" "AAAA:$IP6"; do
        rtype="${pair%%:*}"
        want="${pair#*:}"
        [ -z "$want" ] && continue

        # The apex is an empty name or "@", depending on how the provider
        # writes it. Both mean this domain itself.
        have="$(printf '%s\n' "$current" | awk -F'\t' -v t="$rtype" '
            $2 == t && ($1 == "" || $1 == "@") { print $3; exit }')"

        if [ "$have" = "$want" ]; then
            print_success "  $dom $rtype already $want"
            UNCHANGED=$((UNCHANGED + 1))
        elif [ -z "$have" ]; then
            print_status "  $dom $rtype missing, would add $want"
            TO_WRITE+=("$dom|$rtype|$want|add")
        else
            print_status "  $dom $rtype $have -> $want"
            TO_WRITE+=("$dom|$rtype|$want|update")
        fi
    done
done

echo ""
if [ ${#TO_WRITE[@]} -eq 0 ]; then
    print_success "Every apex record already holds the current address. Nothing to do."
    exit 0
fi

if [ "$MODE" = "check" ]; then
    print_status "--check, so nothing was written."
    exit 0
fi

# =============================================================================
# Write
# =============================================================================
print_header "Writing"

FAILED=0
for entry in "${TO_WRITE[@]}"; do
    IFS='|' read -r dom rtype want how <<< "$entry"
    # dns_update REPLACES the record of that name and type; dns_add would leave
    # the zone with two answers for the apex, which round-robins visitors
    # between a live machine and a dead one.
    if [ "$how" = "update" ]; then
        _ok=0; dns_update "$dom" "@" "$rtype" "$want" "$DNS_TTL" >/dev/null 2>&1 || _ok=1
    else
        _ok=0; dns_add "$dom" "@" "$rtype" "$want" "$DNS_TTL" >/dev/null 2>&1 || _ok=1
    fi

    if [ "$_ok" = "0" ]; then
        print_success "$dom $rtype -> $want"
    else
        print_error "Could not write $dom $rtype"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    print_error "$FAILED record(s) failed. The rest are written."
    print_action "Run this again: it only writes what still differs."
    exit 1
fi

print_success "Every apex record now points at $IP4."
print_status "Everything else is a CNAME pointing here, so it follows within the TTL of ${DNS_TTL}s."
