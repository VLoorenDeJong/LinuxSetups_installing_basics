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
# The four mail DNS records, written through the TransIP API and then checked
# against the nameservers that will actually answer for them.
#
# WHY THIS IS A SEPARATE SCRIPT FROM add_dns_records.sh
#
# add_dns_records.sh manages CNAMEs pointing at their own apex and refuses to
# touch anything else, because mail was TransIP's to run. That refusal is still
# right for it. This script is the other half, owned by the mail stack, and the
# split keeps a hostname sweep from ever rewriting an MX by accident.
#
# ONE RECORD IS SAFE TODAY AND THREE ARE NOT
#
#   DKIM   mail._domainkey TXT    written whenever a key exists on disk
#   SPF    @ TXT v=spf1 ...       MACHINE_IS_LIVE = yes only
#   DMARC  _dmarc TXT             MACHINE_IS_LIVE = yes only
#   MX     @ MX 10 mail.<domain>  MACHINE_IS_LIVE = yes only
#
# DKIM is not gated because it stays correct across the drive swap: it names a
# key, not a machine or an address. Publishing it early costs nothing and means
# the first message the live machine sends is already signed.
#
# The other three name where mail goes. Publishing them before the swap points
# the world's mail at a test box, so they are refused while MACHINE_IS_LIVE is
# no, and go_live.sh calls this script once it has flipped the switch.
#
# IT VALIDATES WHAT IT WROTE, AGAINST THE NAMESERVERS AND NOT THE API
#
# The API answering 201 says TransIP accepted the write. It does not say the
# record resolves, and a DKIM key that resolves wrong is indistinguishable from
# no signature at all to every receiver. So the last step asks the domain's own
# nameservers and compares the published key to the one on disk, byte for byte.
#
# A TXT record over 255 bytes is served as several quoted strings, which is
# normal and not damage: the reassembly here joins them before comparing.
#
# Usage:
#   sudo bash add_mail_dns_records.sh --check    report what would change
#   sudo bash add_mail_dns_records.sh --only <domain>   one zone only
#   sudo bash add_mail_dns_records.sh --dkim     DKIM only, whatever the switch
#   sudo bash add_mail_dns_records.sh            write everything allowed now
#   sudo bash add_mail_dns_records.sh --verify   check the published records only
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
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
trap spinner_stop EXIT

MODE="apply"
ONLY_DKIM=0
# One domain at a time, the same flag and the same spelling add_dns_records.sh
# already uses. A mail domain can belong to a customer who sends their mail
# somewhere else entirely, and writing a selector into their zone is not
# something to do as a side effect of wanting it on your own.
ONLY_DOMAIN=""
_want_only=0
for arg in "$@"; do
    if [ "$_want_only" = "1" ]; then ONLY_DOMAIN="$arg"; _want_only=0; continue; fi
    case "$arg" in
        --check|--dry-run) MODE="check" ;;
        --verify)          MODE="verify" ;;
        --dkim)            ONLY_DKIM=1 ;;
        --only)            _want_only=1 ;;
        --only=*)          ONLY_DOMAIN="${arg#--only=}" ;;
        -h|--help)
            echo "Usage: sudo bash add_mail_dns_records.sh [--check|--verify] [--dkim] [--only <domain>]"
            exit 0 ;;
        *) print_error "Unknown option: $arg"; exit 1 ;;
    esac
done
[ "$_want_only" = "1" ] && { print_error "--only needs a domain."; exit 1; }

if [ "$EUID" -ne 0 ]; then
    print_error "The signing key and the API credential are both root-only."
    print_action "Run: sudo bash $0 $*"
    exit 1
fi

# Two homes, exactly as go_live.sh resolves them: a checkout when a person runs
# it by hand, and the pipeline tree when the console or go_live.sh calls it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="/usr/local/lib/linuxbasics"

if [ -f "/etc/hostings/hostings.conf" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
elif [ -d "$PIPELINE_ROOT/hostings/scripts" ]; then
    REPO_ROOT="$PIPELINE_ROOT"
else
    print_error "No script tree at $PIPELINE_ROOT and none beside this script."
    print_action "Install it: sudo bash add_pipeline_scripts.sh"
    exit 1
fi

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
# The API URL, the credential directory and name, the key file and the account
# name were all read here and used by nothing once dns_preflight took over the
# checking. The provider reads its own.
MAIL_ROOT="$(conf_get MAIL_ROOT /srv/mail)"
# rspamd's own directory, not the mail store: see add_rspamd.sh for why. Both
# scripts read the same two config keys so they cannot drift apart, which is how
# a key signed under one selector gets published under another.
DKIM_DIR="$(conf_get MAIL_DKIM_DIR /var/lib/rspamd/dkim)"
SELECTOR="$(conf_get MAIL_DKIM_SELECTOR mail)"
pub_path() { printf '%s/%s.%s.pub' "$DKIM_DIR" "$1" "$SELECTOR"; }


# Mail domains come from the mailbox rows, read exactly the way every other mail
# script reads them. A domain with no mailbox has no mail to sign.
MAIL_DOMAINS=()
while IFS='|' read -r type name port path subdomain rest; do
    type="$(printf '%s' "$type" | sed 's/#.*//' | tr -d '\r' | xargs)"
    [ "$type" != "mailbox" ] && continue
    subdomain="$(printf '%s' "$subdomain" | tr -d '\r' | xargs)"
    { [ "$subdomain" = "-" ] || [ -z "$subdomain" ]; } && subdomain="$BASE_DOMAIN"
    [ -z "$subdomain" ] && continue
    case " ${MAIL_DOMAINS[*]} " in
        *" $subdomain "*) ;;
        *) MAIL_DOMAINS+=("$subdomain") ;;
    esac
done < <(grep -F '|' "$SITES_CONF" || true)

# Narrowed AFTER the list is built, so an unknown name is refused by naming
# what there was rather than silently doing nothing.
if [ -n "$ONLY_DOMAIN" ]; then
    _found=""
    for d in "${MAIL_DOMAINS[@]}"; do [ "$d" = "$ONLY_DOMAIN" ] && _found="$d"; done
    if [ -z "$_found" ]; then
        print_error "'$ONLY_DOMAIN' has no mailbox row, so this script does not manage its mail records."
        print_status "Domains with mail here: ${MAIL_DOMAINS[*]:-none}"
        exit 1
    fi
    MAIL_DOMAINS=("$_found")
fi

LIVE=0
is_yes "$MACHINE_IS_LIVE" && LIVE=1

print_header "Mail DNS records"
print_status "Config:    $SITES_CONF"
print_status "Domains:   ${MAIL_DOMAINS[*]:-none}"
print_status "Keys:      $DKIM_DIR"
print_status "Selector:  $SELECTOR"
print_status "Mode:      $MODE"
if [ "$LIVE" = "1" ]; then
    print_status "Machine:   live, so MX, SPF and DMARC are in scope"
else
    print_status "Machine:   not live, so DKIM only"
fi

# =============================================================================
# Pre-flight. Everything checked before the first byte is signed.
# =============================================================================
ERRORS=()

# Zero mailbox rows is a STATE, not a fault. add_dovecot.sh records the same
# lesson: treating "nothing to do" as an error left a certificate held open and
# put a permanent retry action in front of an operator with nothing to retry.
if [ ${#MAIL_DOMAINS[@]} -eq 0 ]; then
    print_info "No mailbox rows in $SITES_CONF, so this machine sends no mail of its own."
    print_info "Nothing to publish. Add a mailbox row and run this again."
    exit 0
fi

# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

# What the provider needs is the provider's to say. This checked DNS_API_URL,
# the account name and the key file itself, which are TransIP's requirements in
# a script whose subject is mail. Sourced here, above the checks, because
# dns_preflight has to answer before the list is built.
#
# A five minute token: a writer that runs for seconds has no business holding
# one for half an hour.
DNS_TOKEN_MINUTES=5
export DNS_TOKEN_MINUTES
# shellcheck source=/dev/null
DNS_OPTIONAL=1 . "$(_iface dns.sh)"
if [ "${DNS_READY:-0}" != "1" ]; then
    ERRORS+=("No DNS provider could be loaded. See the message above.")
else
    while IFS= read -r _line; do
        [ -n "$_line" ] && ERRORS+=("$_line")
    done < <(dns_preflight || true)
fi

[ -z "$BASE_DOMAIN" ] && \
    ERRORS+=("No BASE_DOMAIN in $SITES_CONF, and the MX record is built from it")

# jq is handed this with --argjson, so a non-numeric TTL fails mid write-loop
# with some records already written and no summary printed.
case "$DNS_TTL" in
    ''|*[!0-9]*) ERRORS+=("DNS_TTL is '$DNS_TTL', which is not a number of seconds") ;;
esac
# The account name, the key file and the provider's tools are dns_preflight's
# to report now. dig is NOT: this script asks the nameservers directly, which
# is its own validation step and has nothing to do with whose API wrote the
# record.
for tool in dig; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        case "$tool" in
            dig) ERRORS+=("dig is not installed, and the validation needs it. Run: sudo apt-get install -y dnsutils") ;;
            *)   ERRORS+=("$tool is not installed. Run: sudo apt-get install -y $tool") ;;
        esac
    fi
done

for dom in "${MAIL_DOMAINS[@]}"; do
    [ -f "$(pub_path "$dom")" ] || \
        ERRORS+=("No DKIM key for $dom. Run: sudo bash add_rspamd.sh")
done

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

# =============================================================================
# What each record should say.
#
# The public key is stripped to the base64 body: the PEM header, footer and
# newlines are not part of a DKIM record and a receiver that gets them treats
# the key as malformed.
# =============================================================================
dkim_value() {
    local dom pub
    dom="$1"
    pub="$(tr -d '\n' < "$(pub_path "$dom")" \
           | sed 's/-----BEGIN PUBLIC KEY-----//; s/-----END PUBLIC KEY-----//; s/ //g')"
    printf 'v=DKIM1; k=rsa; p=%s' "$pub"
}

# WANT holds domain|name|type|content|match, where match is the prefix that
# identifies OUR record among others of the same name and type. An apex TXT is
# shared with domain-verification records that must not be touched.
WANT=()
for dom in "${MAIL_DOMAINS[@]}"; do
    WANT+=("$dom|${SELECTOR}._domainkey|TXT|$(dkim_value "$dom")|v=DKIM1")

    [ "$ONLY_DKIM" = "1" ] && continue
    [ "$LIVE" = "1" ] || continue

    # -all rather than ~all: a soft fail is advisory and receivers vary in
    # whether they act on it. This says only the MX sends for this domain.
    WANT+=("$dom|@|TXT|v=spf1 mx -all|v=spf1")
    WANT+=("$dom|_dmarc|TXT|v=DMARC1; p=none; rua=mailto:postmaster@$dom|v=DMARC1")
    # The trailing dot is TransIP's own form: it returns "10 mx.transip.email."
    # and a record written without one is reported as different on every later
    # run, so the script would rewrite a correct MX forever.
    WANT+=("$dom|@|MX|10 mail.$BASE_DOMAIN.|")
done

# A hostname with a trailing dot and one without are the same name. Compared
# without it on both sides, so neither form can cause an endless rewrite.
norm() { printf '%s' "${1%.}"; }

# =============================================================================
# The API: it does not talk to one. dns.sh does.
#
# Its own get_token, signature and api() were the fourth of six copies of that
# code across the fleet. DNS_TOKEN_MINUTES keeps the five-minute lifetime this
# script chose: a writer that runs for seconds has no business holding a token
# for half an hour.
# =============================================================================

# Asked of the domain's own nameservers, not of a resolver and not of the API.
# A resolver can still be serving the previous answer from cache, and the API
# only ever says what it accepted.
#
# Deleted by 2a2c360, the commit that moved this script onto dns.sh, while two
# call sites survived. `--check` reaches neither, so every run the script had
# ever had was a run that could not see it. Restored verbatim, and ABOVE both
# callers: the first restoration put it back beside the later one and --verify
# still died, which is the same mistake in miniature.
published_txt() {
    local fqdn="$1" prefix="$2" zone="$3" ns
    # The zone is passed in, never derived from the name. Stripping the first
    # label off mail._domainkey.example.com asks for the NS of
    # _domainkey.example.com, which has none, so every lookup silently fell back
    # to a public resolver: the cache this function exists to avoid.
    ns="$(dig +short NS "$zone" 2>/dev/null | sed 's/\.$//' | head -n1)"
    [ -z "$ns" ] && ns="8.8.8.8"
    # One record per LINE, several quoted strings within a line. Joining the
    # lines first would splice two separate records into one unreadable value,
    # which is exactly what a key rotation looks like while both are published.
    # So: rejoin the strings inside each line, then pick the line we asked for.
    dig +short TXT "$fqdn" "@$ns" 2>/dev/null \
        | sed 's/" "//g' | tr -d '"' \
        | grep "^${prefix}" | head -n1 || true
}

# =============================================================================
# Verify-only. Above the DNS work on purpose: it reports what is PUBLISHED, so
# it needs dig and nothing else. Running it below meant a mode documented as
# "change nothing" still demanded the API credential and could exit 1 because a
# read failed, which says nothing about whether the record resolves.
#
# Deleted by 2a2c360 along with published_txt, while `--verify` stayed in the
# argument parser and in the usage text. MODE was then set, printed, and never
# tested again, so `--verify` fell through and WROTE records: a flag documented
# as checking only was the most dangerous one in the script. Restored verbatim.
# =============================================================================
if [ "$MODE" = "verify" ]; then
    print_header "Published now"
    BAD=0
    for dom in "${MAIL_DOMAINS[@]}"; do
        want="$(dkim_value "$dom")"
        got="$(published_txt "${SELECTOR}._domainkey.$dom" "v=DKIM1" "$dom")"
        if [ -z "$got" ]; then
            print_error "$dom  no DKIM record answers"
            BAD=$((BAD + 1))
        elif [ "$got" = "$want" ]; then
            print_success "$dom  DKIM matches the key on disk"
        else
            print_error "$dom  DKIM does NOT match the key on disk"
            print_info  "    published: $got"
            print_info  "    on disk:   $want"
            BAD=$((BAD + 1))
        fi

        # Only DKIM is validated, and saying so is the point: a live machine
        # whose SPF or MX never landed must not read as fully checked.
        if [ "$LIVE" = "1" ]; then
            print_info "$dom  MX, SPF and DMARC are not read back by this check."
        fi
    done
    [ "$BAD" -gt 0 ] && exit 1
    exit 0
fi

# dns.sh was sourced at the pre-flight, where dns_preflight needed it, so this
# is no longer where the provider arrives. The name it reports is the
# provider's own, not a URL out of this script's config.
spinner_stop
print_status "DNS provider: ${DNS_PROVIDER_NAME:-unknown}."

TO_WRITE=()
UNCHANGED=0

print_header "What would change"

declare -A CURRENT=()
for dom in "${MAIL_DOMAINS[@]}"; do
    [ -n "${CURRENT[$dom]:-}" ] && continue
    spinner_start "Reading the current records for $dom"
    # dns_records, not dns_list: the normalised name<TAB>type<TAB>content<TAB>ttl
    # dns.sh promises, rather than the provider's own JSON. This file used to
    # jq `.dnsEntries[]` twice, which is TransIP's field names in a script that
    # is not supposed to know whose they are.
    CURRENT[$dom]="$(dns_records "$dom")" || {
        spinner_stop
        print_error "Could not read the records for $dom."
        exit 1
    }
    spinner_stop
done

for entry in "${WANT[@]}"; do
    IFS='|' read -r dom rname rtype want match <<< "$entry"

    # TransIP writes the apex as an empty name; the panel shows it as @.
    api_name="$rname"
    [ "$rname" = "@" ] && api_name=""

    # Every record of this name and type whose content starts with $match, in
    # the provider's own order, as content<TAB>ttl. One filter, used three
    # times below: the first is the record acted on, the rest are reported.
    matches="$(printf '%s\n' "${CURRENT[$dom]}" | awk -F'\t' \
        -v n="$api_name" -v t="$rtype" -v m="$match" '
        $2 != t { next }
        !($1 == n || (n == "" && ($1 == "@" || $1 == ""))) { next }
        m != "" && index($3, m) != 1 { next }
        { print $3 "\t" $4 }')"

    have="$(printf '%s\n' "$matches" | sed -n '1s/\t.*//p')"

    # Only the first match is updated. A second apex MX would survive and keep
    # sending mail to the old target, so the leftovers are named rather than
    # silently left: this script writes one record, it does not own the zone.
    extra="$(printf '%s\n' "$matches" | sed -n '2,$s/\t.*//p')"
    if [ -n "$extra" ]; then
        print_action "  $dom  $rname $rtype has more than one record. These are NOT touched:"
        while IFS= read -r line; do print_info "      $line"; done <<< "$extra"
    fi

    # PATCH identifies an entry by name, type AND expire, so the existing TTL
    # has to be the one sent or the update matches nothing and silently no-ops.
    have_ttl="$(printf '%s\n' "$matches" | sed -n '1s/^[^\t]*\t//p')"
    [ -z "$have_ttl" ] && have_ttl="$DNS_TTL"

    label="${rname} ${rtype}"

    if [ "$(norm "$have")" = "$(norm "$want")" ]; then
        print_success "  $dom  $label already correct"
        UNCHANGED=$((UNCHANGED + 1))
    elif [ -z "$have" ]; then
        print_status "  $dom  $label missing, would add"
        TO_WRITE+=("$dom|$api_name|$rtype|$want|$DNS_TTL|POST")
    else
        print_status "  $dom  $label differs, would update"
        print_info   "      now:  $have"
        print_info   "      want: $want"
        TO_WRITE+=("$dom|$api_name|$rtype|$want|$have_ttl|PATCH")
    fi
done

if [ "$LIVE" != "1" ] && [ "$ONLY_DKIM" != "1" ]; then
    echo ""
    print_info "MX, SPF and DMARC were not considered: MACHINE_IS_LIVE = no."
    print_info "go_live.sh calls this script again once it has flipped that switch."
fi

echo ""
if [ ${#TO_WRITE[@]} -eq 0 ]; then
    # NOT an early exit. "Nothing differs at the API" is not "the record still
    # resolves": a zone edited elsewhere, or a nameserver that lost it, looks
    # exactly like this. The steady-state run is the one that should prove it,
    # so this falls through to the validation below with nothing to write.
    print_success "Every record in scope already matches. Checking they still resolve."
fi

if [ "$MODE" = "check" ]; then
    print_status "--check, so nothing was written."
    print_action "Write them: sudo bash $0"
    exit 0
fi

# =============================================================================
# Write
# =============================================================================
FAILED=0
WROTE=0
if [ ${#TO_WRITE[@]} -gt 0 ]; then
    print_header "Writing"
fi
for entry in ${TO_WRITE+"${TO_WRITE[@]}"}; do
    IFS='|' read -r dom api_name rtype want ttl method <<< "$entry"
    show="${api_name:-@} $rtype"
    # POST adds, PATCH replaces; the interface says which in a verb rather than
    # in an HTTP method, so no caller here names one.
    #
    # TransIP's own reason is the only useful thing on this path. Discarding it
    # leaves the operator with "was refused" and nothing to act on.
    log="$(mktemp)"
    if [ "$method" = "PATCH" ]; then
        _ok=0; dns_update "$dom" "$api_name" "$rtype" "$want" "$ttl" >"$log" 2>&1 || _ok=1
    else
        _ok=0; dns_add "$dom" "$api_name" "$rtype" "$want" "$ttl" >"$log" 2>&1 || _ok=1
    fi
    if [ "$_ok" = "0" ]; then
        print_success "$dom  $show written"
        WROTE=$((WROTE + 1))
    else
        print_error "$dom  $show was refused by TransIP:"
        print_error "  $(head -c 400 "$log")"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$log"
done

# =============================================================================
# Validate. This is the point of the script.
#
# TransIP accepting a write is not the record resolving, and a DKIM key that
# resolves wrong looks exactly like no signature at all to every receiver.
# =============================================================================
print_header "Checking what the nameservers actually serve"

BAD=0
for dom in "${MAIL_DOMAINS[@]}"; do
    want="$(dkim_value "$dom")"
    got=""
    waited=0
    spinner_start "Waiting for $dom to serve its DKIM record"
    while [ "$waited" -lt 60 ]; do
        got="$(published_txt "${SELECTOR}._domainkey.$dom" "v=DKIM1" "$dom")"
        [ "$got" = "$want" ] && break
        sleep 5
        waited=$((waited + 5))
    done
    spinner_stop

    if [ "$got" = "$want" ]; then
        print_success "$dom  DKIM published and matches the key on disk (${waited}s)"
    elif [ -z "$got" ]; then
        print_error "$dom  no DKIM record answered within 60s"
        print_info  "    TransIP accepted the write, so this is propagation, not a refusal."
        print_action "    Check again in a few minutes: sudo bash $0 --verify"
        BAD=$((BAD + 1))
    else
        print_error "$dom  the published DKIM key does NOT match the key on disk"
        print_info  "    published: $got"
        print_info  "    on disk:   $want"
        print_action "    Every signature this machine makes will fail until that is fixed."
        BAD=$((BAD + 1))
    fi
done

echo ""
if [ "$FAILED" -gt 0 ]; then
    print_error "$FAILED record(s) were refused. The rest are written."
    print_action "Run this again: it only writes what still differs."
    exit 1
fi

if [ "$BAD" -gt 0 ]; then
    print_error "$WROTE record(s) written, but $BAD did not validate."
    exit 1
fi

print_success "$WROTE record(s) written and validated, $UNCHANGED already correct."
if [ "$LIVE" != "1" ]; then
    print_info "DKIM only. The MX, SPF and DMARC records follow at go-live."
fi
