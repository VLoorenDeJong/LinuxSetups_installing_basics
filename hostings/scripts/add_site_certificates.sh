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
# Request a Let's Encrypt certificate for every hostname in
# /etc/hostings/hostings.conf, plus the deprecated domains.
#
# CERTONLY. CERTBOT DOES NOT TOUCH APACHE CONFIG.
#
# The previous version ran `certbot --apache`, which rewrites vhosts in place to
# add the :443 block. That produced the failure this machine actually had on
# 2026-08-01: two writers for one file, so HTTP was served from one tree and
# HTTPS from certbot's copies in another, and editing one changed nothing a real
# visitor saw.
#
# Now certbot does exactly one job: fetch and renew certificates into
# /etc/letsencrypt/live/. add_app_vhosts.sh owns every vhost and writes both
# blocks itself.
#
# The order is therefore:
#
#   add_app_vhosts.sh     writes :80, including the ACME challenge path
#   add_site_certificates.sh  this script, gets the certificates
#   add_app_vhosts.sh     writes :443 now that the certificates exist
#
# Running the vhost script twice is not a workaround. A :443 block naming a
# certificate that does not exist fails configtest and Apache will not start.
#
# THE WHOLE SET IS REHEARSED BEFORE ANY OF IT IS ISSUED
#
# A real run makes two passes. The first tries every hostname against staging.
# If a single one fails, nothing is requested for real and no production rate
# limit is spent. Only a clean sweep earns the second pass.
#
# It used to rehearse one hostname and immediately issue it, which meant a run
# could issue ten certificates and then fail on the eleventh, leaving the set
# half done.
#
# --staging performs the whole challenge against Let's Encrypt's staging server
# and KEEPS the result. The certificate is untrusted, so a browser warns, and
# that warning is how a rehearsed row is told apart from a promoted one. It also
# means the site can be visited over HTTPS and checked before a real issuance is
# spent on it. promote_certificate.sh replaces one when it has been checked.
#
# This was --dry-run until 2026-08-16, which kept nothing and therefore left
# every unpromoted row with no certificate and no HTTPS at all.
#
# It is automatic rather than a flag, because the limit that bites is FAILED
# VALIDATIONS: a small number per hostname per hour, currently 5, and the figure
# has only ever got tighter. "Linux Install.docx" records the older account-wide
# 60 an hour. Either way a first run with a misconfigured webroot burns it on
# every hostname at once, and staging allows around 30,000 a week.
#
# THREE REFUSALS, ALL PROTECTING THE RATE LIMIT
#
# Production also allows 50 certificates per registered domain per week and 5
# duplicates. A loop that re-requests on every run burns through both, and the
# lockout lasts days. So a hostname is skipped when it has no vhost, when DNS
# does not point here, or when it is already covered.
#
# THIS IS THE MANUAL'S PROCEDURE, AUTOMATED
#
# "Linux Install.docx" already does test-then-real: certbot --test-cert, check
# every site, then certbot --apache for real. Two changes.
#
# --test-cert installs an untrusted certificate, which is why the manual then
# says "re apply the certificates this is now for real". --dry-run installs
# nothing, so there is no second pass and no certificate to replace.
#
# And the manual warns, in its own words: "The SSL certification changes the
# apache config copied earlier so if it fails you need to reconfigure apache".
# That is the failure this machine actually had, found on 2026-08-01, a year
# later. certonly removes the cause rather than the symptom.
#
# RENEWAL IS TESTED, NOT ASSUMED
#
# add_certbot.sh enables certbot.timer, which is necessary and not sufficient:
# the timer firing proves nothing about whether a renewal would succeed. After
# issuing, this runs `certbot renew --dry-run`, which replays what will happen
# in 60 days for every certificate on the machine. Without it, the first sign of
# a broken renewal is a browser warning on the day one expires.
#
# Usage:
#   sudo env CERT_EMAIL=you@example.com ./add_site_certificates.sh
#
# `sudo env` is required. A plain CERT_EMAIL=... sudo ... is stripped by
# sudo's env_reset and the variable arrives empty.
#
# Environment:
#   CERT_DRY_RUN=1     issue from the STAGING endpoint. It stores a real
#                      certificate that browsers will not trust, so the row can
#                      be visited and checked. It is not certbot's --dry-run and
#                      it does issue: see the --staging comment further down
#   ONLY_ENVS=live     narrow this run to one environment, comma separated
#   SKIP_DNS_CHECK=1   skip the address-record lookup entirely. Not needed to
#                      issue a certificate: DNS-01 never requires one
#   SITES_CONF         override the config location
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

# A redraw needs a terminal. In a Jenkins log \r is not a carriage return, so
# every update lands as its own line and \033[K blanks it: seventeen units
# printed one line of text and sixteen empty ones. Silent there instead, since
# each of these loops already prints a summary when it finishes.
redraw() { [ -t 1 ] || return 0; printf "$@"; }

# LIST_HOSTS=1 prints every hostname this script would request a certificate
# for, one per line, and requests nothing. maintain_services.sh compares it
# against the list add_app_vhosts.sh would publish: the two carry duplicated
# hostname logic on purpose, so each stays runnable alone, and this is the guard
# that makes the duplication safe.
LIST_HOSTS="${LIST_HOSTS:-0}"

if [ "$LIST_HOSTS" = "1" ]; then
    exec 3>&1 1>&2
fi

# --dry-run and --only do what CERT_DRY_RUN and ONLY_ENVS do, and exist because
# of how sudo matches commands. A sudoers rule names a literal command, so
# `sudo env VAR=1 bash script` needs /usr/bin/env granted, and env can run
# anything as root. A flag keeps the grant on bash and this one script.
#
# The environment variables still work, for a run by hand.
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) CERT_DRY_RUN=1; shift ;;
        --real)    CERT_DRY_RUN=0; shift ;;
        --only)    ONLY_ENVS="$2"; shift 2 ;;
        --only=*)  ONLY_ENVS="${1#--only=}"; shift ;;
        # A flag as well as the variable, because sudo's env_reset drops
        # ONLY_ROWS, and `sudo env ONLY_ROWS=x bash ...` is a different command
        # string that the NOPASSWD rule for this script does not match.
        --only-row)   ONLY_ROWS="$2"; shift 2 ;;
        --only-row=*) ONLY_ROWS="${1#--only-row=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--dry-run|--real] [--only <env,env>] [--only-row <name,name>]" >&2
            exit 1
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$LIST_HOSTS" != "1" ] && [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo env CERT_EMAIL=you@example.com $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi

if [ "$LIST_HOSTS" != "1" ] && ! command -v certbot >/dev/null 2>&1; then
    print_error "certbot not found."
    print_action "Run add_certbot.sh first, then this script."
    exit 1
fi

# -----------------------------------------------------------------------------
# One certbot at a time, machine wide.
#
# Certbot holds its own lock and the loser simply dies: "Another instance of
# Certbot is already running", once per remaining hostname. That happened with
# the apply job and the certificates job running together, and Jenkins cannot
# prevent it because disableConcurrentBuilds only stops a job clashing with
# itself.
#
# It refuses rather than waits. A queued build holds a Jenkins executor and then
# dies on the job's own 30 minute timeout with nothing in the log explaining
# why, which is worse than a red build that says exactly what happened.
# -----------------------------------------------------------------------------
if [ "$LIST_HOSTS" != "1" ] && command -v flock >/dev/null 2>&1; then
    exec 9>/var/lock/add_site_certificates.lock
    if ! flock -n 9; then
        print_error "Another certificate run is in progress on this machine."
        print_info "Only one may run at a time: certbot holds its own lock and"
        print_info "the second one dies part way through, one hostname at a time."
        echo ""
        print_info "The apply job and the certificates job both call this script."
        print_action "Wait for the other build to finish, then run this again."
        print_info "Nothing was requested, so no rate limit was spent."
        exit 1
    fi
fi

# CERT_EMAIL is checked further down, after conf_get exists: it can come from
# the config as well as from the environment.

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()
_trim() {
    local -n __t="$1"
    local __tv="$2"
    __tv="${__tv#"${__tv%%[![:space:]]*}"}"
    __tv="${__tv%"${__tv##*[![:space:]]}"}"
    [ "$__tv" = "-" ] && __tv=""
    __t="$__tv"
}
_conf_get() {
    local -n __out="$1"
    # Locals prefixed: a caller passing a target named like one of them would be
    # writing into this function's scope instead of its own.
    local __ck="$2" __cd="$3" __cv
    if [ -n "${_CONF_CACHE[$__ck]+set}" ]; then
        __cv="${_CONF_CACHE[$__ck]}"
    else
        __cv="$(sed -n "s/^[[:space:]]*${__ck}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # A CRLF config leaves a carriage return on the end of the value, and
        # _trim only removes whitespace.
        __cv="${__cv//$'\r'/}"
        _trim __cv "${__cv%%#*}"
        _CONF_CACHE[$__ck]="$__cv"
    fi
    __out="${__cv:-$__cd}"
}

conf_get() {
    local _v
    _conf_get _v "$1" "$2"
    echo "$_v"
}

conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# Does this row exist in this environment?
#
# The Envs field is empty for almost everything, meaning all of them. It exists
# because a test environment proves a build runs, which needs one instance of an
# application rather than one per customer: the four progress tenants are live
# only, and a single row covers test.
row_in_env() {
    local list="$1" env="$2" e
    _trim list "$list"
    [ -z "$list" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in ${_re+"${_re[@]}"}; do
        _trim e "$e"
        [ "$e" = "$env" ] && return 0
    done
    return 1
}

# One place that decides what counts as yes. Accepts y, yes, true and 1 in any
# case; everything else, including empty and a dash, is no. Duplicated verbatim
# from the other scripts, so this one stays runnable on its own.
is_yes() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "${v,,}" in
        y|yes|true|1) return 0 ;;
        *)            return 1 ;;
    esac
}

# A field holding a single dash means empty. `| | |` cannot be counted by eye.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
if [ -z "$BASE_DOMAIN" ]; then
    print_error "No BASE_DOMAIN in $SITES_CONF"
    exit 1
fi

# The contact address is not a secret and does not change, so it belongs in the
# config rather than being retyped on every run. The environment still wins, for
# a one-off with a different address and so a Jenkins job can pass one.
if [ -z "$CERT_EMAIL" ]; then
    CERT_EMAIL="$(conf_get CERT_EMAIL "")"
fi

if [ "$LIST_HOSTS" != "1" ] && [ -z "$CERT_EMAIL" ]; then
    print_error "No contact address, and certbot needs one to warn you before expiry."
    print_action "Put it in $SITES_CONF:"
    print_action "  CERT_EMAIL = you@example.com"
    print_action "Or pass it once: sudo env CERT_EMAIL=you@example.com $0"
    print_action "sudo env is required: a plain VAR=... sudo ... is stripped by env_reset."
    exit 1
fi

# Must match add_app_vhosts.sh, or a certificate is requested for a name
# that has no vhost and validation fails
IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
DEFAULT_PUBLISH="$(trim "${ALL_ENVS[0]}")"
# Must match add_app_vhosts.sh exactly. A narrower default here would request
# certificates for live hostnames only while the generator publishes test ones
# too, leaving the test sites on HTTP forever with nothing saying why.
IFS=',' read -r -a PUBLISH_ENVS <<< "$(conf_get PUBLISH_ENVS "$(conf_get ENVS live)")"
for i in "${!PUBLISH_ENVS[@]}"; do
    PUBLISH_ENVS[$i]="$(trim "${PUBLISH_ENVS[$i]}")"
done

# ONLY_ENVS narrows a run to one environment.
#
# Not a default, and never written to the config: the full set is what the vhost
# generator publishes, and requesting fewer by default would leave those sites on
# HTTP for ever with nothing saying why. LIST_HOSTS deliberately ignores it too,
# so the cross-check keeps comparing the whole picture.
#
# It exists because the rate limit is per hostname and the first real run of a
# new machine is the one most likely to fail. Doing live first, seeing it work,
# then doing test costs nothing and stops one mistake taking everything with it.
#
#   sudo env ONLY_ENVS=live ./add_site_certificates.sh
if [ -n "${ONLY_ENVS:-}" ] && [ "$LIST_HOSTS" != "1" ]; then
    IFS=',' read -r -a _only <<< "$ONLY_ENVS"
    _kept=()
    for e in "${_only[@]}"; do
        e="$(trim "$e")"
        [ -z "$e" ] && continue
        _found=0
        for p in "${PUBLISH_ENVS[@]}"; do
            [ "$p" = "$e" ] && _found=1 && _kept+=("$e")
        done
        if [ "$_found" -eq 0 ]; then
            print_error "ONLY_ENVS names '$e', which is not a published environment."
            print_action "Published environments are: ${PUBLISH_ENVS[*]}"
            exit 1
        fi
    done
    PUBLISH_ENVS=("${_kept[@]}")
fi

# ONLY_ROWS is the other axis: narrow to named rows rather than to environments,
# so adding one site asks for its certificate without touching anyone else's.
# Comma separated, matched on the second column.
#
#   sudo env ONLY_ROWS=mvp_progress ./add_site_certificates.sh
#
# LIST_HOSTS ignores it, for the same reason it ignores ONLY_ENVS: the
# cross-check has to keep comparing the whole picture.
ONLY_ROWS="$(trim "${ONLY_ROWS:-}")"
declare -A _WANTED=()
if [ -n "$ONLY_ROWS" ] && [ "$LIST_HOSTS" != "1" ]; then
    IFS=',' read -r -a _rw <<< "$ONLY_ROWS"
    for _r in "${_rw[@]}"; do
        _r="$(trim "$_r")"
        [ -z "$_r" ] && continue
        if ! awk -F'|' -v n="$_r" '
                /^[[:space:]]*#/ { next }
                NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                         if ($2 == n) found = 1 }
                END { exit !found }' "$SITES_CONF"; then
            print_error "ONLY_ROWS names '$_r', which is no row in $SITES_CONF."
            print_action "Names are the second column. To list them:"
            print_action "  awk -F'|' '!/^ *#/ && NF>1 {print \$2}' $SITES_CONF"
            exit 1
        fi
        _WANTED[$_r]=1
    done
fi

# Everything, when nothing was asked for or when only listing.
row_selected() {
    [ ${#_WANTED[@]} -eq 0 ] && return 0
    [ -n "${_WANTED[$1]:-}" ]
}

# The webroot the :80 vhosts serve /.well-known/acme-challenge/ from. Written by
# add_app_vhosts.sh; created here too so a manual run cannot fail on it.
WEBROOT="/var/www/certbot"
if [ "$LIST_HOSTS" != "1" ]; then
    mkdir -p "$WEBROOT"
    chmod 755 "$WEBROOT"
fi

# =============================================================================
# DNS-01, always.
#
# Let's Encrypt reads a TXT record in the zone instead of fetching a file from
# this machine, so a certificate can be issued while the router still sends port
# 80 somewhere else. Chosen over HTTP-01 permanently, not only until the swap:
# the TransIP API is needed anyway to manage the subdomains, so one way of
# proving a domain is one thing to keep working instead of two.
# =============================================================================
# The hook is COPIED to a fixed path rather than called where it sits. Certbot
# writes the hook command into the renewal config, and renewal runs from a timer
# in 60 days: a path inside a git checkout, a Jenkins workspace most of all,
# will not be there. Copied on every run, so editing the repo copy is still how
# it changes.
CHALLENGE_HOOK="/usr/local/sbin/transip_dns_challenge.sh"
CHALLENGE_SOURCE="$SCRIPT_DIR/transip_dns_challenge.sh"
CHALLENGE_ARGS=(
    --manual
    --preferred-challenges dns
    --manual-auth-hook    "$CHALLENGE_HOOK --add"
    --manual-cleanup-hook "$CHALLENGE_HOOK --delete"
)

print_header "Site certificates"
print_status "Config:     $SITES_CONF"
print_status "Email:      $CERT_EMAIL"
print_status "Challenge:  DNS-01 through the TransIP API"
print_status "Publishing: ${PUBLISH_ENVS[*]}"

if [ "$LIST_HOSTS" != "1" ]; then
    if [ ! -f "$CHALLENGE_SOURCE" ]; then
        print_error "The DNS-01 hook is missing: $CHALLENGE_SOURCE"
        exit 1
    fi
    # Copied, not linked: renewal must not depend on the checkout still being
    # there. The copy cannot find hostings.conf from /usr/local/sbin, and does
    # not need to: the key and account paths it falls back to are the ones the
    # config would have named.
    install -m 0700 -o root -g root "$CHALLENGE_SOURCE" "$CHALLENGE_HOOK"
fi

CERTBOT_EXTRA=()
# One switch decides this, and it is the same switch that decides everything
# else about being live. Two flags that can disagree is what previously had the
# config announcing that no certificate existed while fifteen did.
#
# --dry-run and --real still work: they are one command, not a file, so nothing
# is left flipped by accident afterwards.
if ! is_yes "$(conf_get MACHINE_IS_LIVE no)" && [ -z "${CERT_DRY_RUN:-}" ]; then
    CERT_DRY_RUN=1
    print_info "MACHINE_IS_LIVE = no, so certificates come from the staging server."
    print_action "Flip it after the drive swap. For one real run now: $0 --real"
fi

if [ "${CERT_DRY_RUN:-0}" = "1" ]; then
    # --staging, not --dry-run. A stored test certificate is what lets the site
    # be visited over HTTPS and checked before a real issuance is spent on it.
    # Browsers do not trust it, which is the point: the untrusted warning is how
    # you can tell a rehearsed row from a promoted one.
    CERTBOT_EXTRA+=(--staging)
    print_info "CERT_DRY_RUN=1, using the staging endpoint. Browsers will not trust these."
    print_action "Promote one with: promote_certificate.sh <hostname>"
fi

# -----------------------------------------------------------------------------
# This machine's public addresses, resolved once. A hostname pointing somewhere
# else is the most common reason validation fails, and it fails slowly, after
# the rate limit has already been spent.
# -----------------------------------------------------------------------------
MY_IP4=""
MY_IP6=""
if [ "$LIST_HOSTS" != "1" ] && [ "${SKIP_DNS_CHECK:-0}" != "1" ]; then
    # Through public_ip.sh. This block named two v4 hosts and one v6 host, and
    # two other scripts named different ones, so the policy lived in three
    # places and nobody could change it in one. The shape check that was here
    # is in the interface now, so a provider answering an error page is
    # rejected rather than compared against a DNS record.
# A SCRIPT INSTALLED TO /usr/local/sbin HAS NO SIBLINGS, which is the fault of
# 2026-09-02 that made every sibling lookup fail silently. The interfaces live
# in the pipeline tree, so look there when they are not beside this file.
_iface() {
    local d="$SCRIPT_DIR"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

    . "$(_iface public_ip.sh)"
    MY_IP4="$(public_ip4 || true)"
    MY_IP6="$(public_ip6 || true)"

    if [ -z "$MY_IP4" ] && [ -z "$MY_IP6" ]; then
        print_info "Could not determine this machine's public IP, so the DNS check is skipped."
        print_info "Certificates will still be requested. A wrong DNS record will fail slowly."
    else
        [ -n "$MY_IP4" ] && print_status "Public IPv4: $MY_IP4"
        [ -n "$MY_IP6" ] && print_status "Public IPv6: $MY_IP6"
    fi
fi

ISSUED=()
ALREADY=()
NO_VHOST_YET=()
NO_DNS_RECORD=()
FAILED=()

_resolve_host() {
    local -n __h="$1"
    # Prefixed for the same reason as _conf_get's: a caller's target named
    # `prefix` would otherwise be shadowed by this function's own.
    local __rs="$2" __rp="$3" __rl
    [ -z "$__rs" ] && return 1
    case "$__rs" in
        @*)
            if [ -z "$__rp" ]; then
                # The apex itself
                __h="$BASE_DOMAIN"
            else
                # A non-live environment cannot use the apex, so it needs a
                # label. "@" alone gives test-example.com, which reads as a
                # different domain rather than a copy of this site; "@portfolio"
                # gives test-portfolio.example.com, which reads correctly.
                __rl="${__rs#@}"
                if [ -n "$__rl" ]; then
                    __h="${__rp}${__rl}.${BASE_DOMAIN}"
                else
                    __h="${__rp}${BASE_DOMAIN}"
                fi
            fi
            ;;
        =*)
            if [ -z "$__rp" ]; then
                # The live environment answers on the real domain
                __h="${__rs#=}"
            else
                # Every other environment becomes a SUBDOMAIN of it, so the
                # prefix's trailing hyphen is dropped: test- gives
                # test.example.org, not test-example.org, which
                # would be a domain nobody owns. That record has to exist on the
                # customer domain: there is no wildcard there.
                __h="${__rp%%-}.${__rs#=}"
            fi
            ;;
        *)  __h="${__rp}${__rs}.${BASE_DOMAIN}" ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Request one certificate. Every refusal happens before certbot is called, so a
# skipped hostname costs nothing against the rate limit.
# -----------------------------------------------------------------------------
request_cert() {
    local host="$1" extra_names="$2" resolved log exit_code covered_names all_covered n
    local -a domain_args=(--domain "$host")

    # LIST_HOSTS reports the intent and stops before every refusal below, so the
    # list is what this script would ASK FOR rather than what it would get
    # today. That is the right comparison: a hostname skipped because DNS has
    # not propagated yet still needs a vhost.
    if [ "$LIST_HOSTS" = "1" ]; then
        echo "$host" >&3
        for n in $extra_names; do echo "$n" >&3; done
        return 0
    fi

    # -R, not -r: sites-enabled holds symlinks, and -r skips symlinks it meets
    # while recursing, so this matched nothing and skipped every hostname.
    #
    # No longer a skip either. DNS-01 proves the domain through a TXT record and
    # never asks this machine for anything, so a certificate can be issued
    # before its vhost exists. Worth saying, because the certificate does
    # nothing until one does.
    if ! grep -Rqs "ServerName[[:space:]]\+${host}\b" /etc/apache2/sites-enabled/; then
        print_info "$host has no enabled vhost yet. Requesting the certificate anyway."
        NO_VHOST_YET+=("$host")
    fi

    # certbot's own view, rather than guessing from /etc/letsencrypt/live, which
    # keeps stale directories after a revoke.
    #
    # Matched as a whole space-delimited name, not as a substring. A \b word
    # boundary is not enough: a dot is a non-word character, so example.com
    # matches inside demo.example.com and the apex would be reported as
    # already covered by any subdomain's certificate, then never issued.
    #
    # Every name on the request has to be covered, not just the first. A
    # certificate for example.com alone would otherwise count as done and
    # www.example.com would never be added to it.
    # Asked once for the whole run, not once per hostname. certbot certificates
    # takes about a second and the answer cannot change while this is running,
    # so fifteen hostnames paid fifteen seconds for one fact.
    covered_names="$COVERED_NAMES"
    all_covered=1
    for n in "$host" $extra_names; do
        printf '%s\n' "$covered_names" | grep -qxF "$n" || all_covered=0
    done
    if [ "$all_covered" -eq 1 ]; then
        ALREADY+=("$host")
        return 0
    fi

    # Under DNS-01 a name that does not resolve is not a reason to refuse. The
    # challenge is a TXT record in the zone and Let's Encrypt never asks for an
    # A record, so mail.example.com issued perfectly well on 2026-09-03 with
    # no address record at all: item 43 had to work around this check with
    # SKIP_DNS_CHECK=1 to get it.
    #
    # The lookup stays, because a name that has stopped existing is worth
    # seeing. example.nl went NXDOMAIN on 2026-08-02 when its registration
    # lapsed, and nothing else here notices. Reported, never a refusal: the
    # per-host staging pass below catches a zone that really cannot be written,
    # and costs no production rate limit doing it.
    resolved=""
    if [ "${SKIP_DNS_CHECK:-0}" != "1" ]; then
        resolved="$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
        if [ -z "$resolved" ]; then
            NO_DNS_RECORD+=("$host")
            print_info "$host has no address record. DNS-01 does not need one. Requesting anyway."
        fi
    fi

    # Where the name points does not matter under DNS-01. The challenge is a TXT
    # record in the zone, so a name pointing at the machine being replaced still
    # validates from here. Reported, because a name pointing somewhere
    # unexpected is worth seeing, but no longer a reason to skip it.
    if [ -n "$resolved" ] && { [ -n "$MY_IP4" ] || [ -n "$MY_IP6" ]; }; then
        if ! { [ -n "$MY_IP4" ] && grep -qxF "$MY_IP4" <<< "$resolved"; } &&
           ! { [ -n "$MY_IP6" ] && grep -qxF "$MY_IP6" <<< "$resolved"; }; then
            print_info "$host points at $(echo "$resolved" | tr '\n' ' '), not this machine. Requesting anyway."
        fi
    fi

    for n in $extra_names; do
        domain_args+=(--domain "$n")
    done

    # -------------------------------------------------------------------------
    # Dry run first, always.
    #
    # --dry-run performs the whole challenge against Let's Encrypt's STAGING
    # server and throws the result away. Nothing is written to
    # /etc/letsencrypt/live, so there is no test certificate to replace
    # afterwards. That is the difference between --dry-run and a bare --staging,
    # which does install an untrusted certificate you then have to delete.
    #
    # It is not optional because the production limit that bites is 5 FAILED
    # VALIDATIONS per hostname per hour. A first run with a misconfigured
    # webroot burns that on every hostname at once and locks you out for hours.
    # Staging allows roughly 30,000 a week, so this costs nothing.
    #
    # Skipped when the whole run is already a dry run.
    # -------------------------------------------------------------------------
    # Not needed when the whole set was rehearsed a moment ago, which is what
    # the real pass is now preceded by.
    if [ "${CERT_DRY_RUN:-0}" != "1" ] && [ "${SKIP_PER_HOST_STAGING:-0}" != "1" ]; then
        print_status "Testing $host against staging first..."
        log="$(mktemp)"
        if ! certbot certonly \
            "${CHALLENGE_ARGS[@]}" \
            --non-interactive --agree-tos --email "$CERT_EMAIL" \
            --dry-run "${domain_args[@]}" >"$log" 2>&1; then
            print_error "Staging test failed for $host, so nothing was requested for real."
            print_info "This costs no production rate limit. Last 20 lines:"
            tail -n 20 "$log"
            print_action "Full log: $log"
            FAILED+=("$host (staging test failed)")
            return 0
        fi
        rm -f "$log"
        print_success "Staging test passed."
    fi

    print_status "Requesting a certificate for $host${extra_names:+ (+$extra_names)}..."

    log="$(mktemp)"
    if certbot certonly \
        "${CHALLENGE_ARGS[@]}" \
        --non-interactive \
        --agree-tos \
        --email "$CERT_EMAIL" \
        --keep-until-expiring \
        --deploy-hook "systemctl reload apache2" \
        "${domain_args[@]}" \
        "${CERTBOT_EXTRA[@]}" >"$log" 2>&1; then
        if [ "${CERT_DRY_RUN:-0}" = "1" ]; then
            print_success "$host has a staging certificate. Browsers will not trust it."
        else
            print_success "$host secured."
        fi
        ISSUED+=("$host")
        rm -f "$log"
    else
        exit_code=$?
        # Named rather than left as a generic failure. This script's own lock
        # cannot prevent certbot.timer starting a renewal underneath it, and
        # "exit 1" with twenty lines of log reads like a broken config.
        if grep -q "Another instance of Certbot is already running" "$log" 2>/dev/null; then
            print_error "$host: certbot is busy elsewhere, probably the renewal timer."
            print_action "Nothing is wrong with the config. Check with: systemctl status certbot.timer"
            print_action "Then run this again."
            FAILED+=("$host (certbot busy)")
            rm -f "$log"
            return 0
        fi
        print_error "certbot failed for $host (exit $exit_code). Last 20 lines:"
        tail -n 20 "$log"
        print_action "Full log: $log"
        FAILED+=("$host (exit $exit_code)")
        # Deliberately not cleaned up: it is the only record of why this failed
    fi
}


# Wrapped in a function so the whole set can be rehearsed before any of it is
# issued. Called twice: once with every request forced to a dry run, and again
# for real only if nothing failed.
request_all_hosts() {
# -----------------------------------------------------------------------------
# Every hostname the vhost generator publishes
# -----------------------------------------------------------------------------
while IFS='|' read -r type name port path sub datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    _trim type "$type"
    _trim name "$name"
    _trim sub "$sub"

    [ -z "$type" ] && continue
    # A mailbox's Subdomain is a MAIL DOMAIN, not a web subdomain. Read as one it
    # becomes example.org.example.com, a name nobody owns, and the run
    # then reports it as missing from DNS on every pass. Mail certificates are
    # Dovecot's and Postfix's, not this script's.
    [ "$type" = "mailbox" ] && continue
    [ -z "$sub" ] && continue
    row_selected "$name" || continue

    for env in "${PUBLISH_ENVS[@]}"; do
        row_in_env "$rowenvs" "$env" || continue
        env_upper="${env^^}"
        _conf_get prefix "${env_upper}_HOST_PREFIX" ""

        # A proxy row is one service on one port however many environments
        # exist. Must match the vhost generator exactly: a mismatch either
        # requests a certificate for a hostname with no vhost, which fails
        # validation, or leaves a published hostname on HTTP with nothing
        # saying why.
        case "$type" in
            proxy) [ "$env" != "$DEFAULT_PUBLISH" ] && continue ;;
        esac

        if _resolve_host host "$sub" "$prefix"; then
            # A bare domain also answers on www and redirects to itself, so the
            # certificate has to cover both or the redirect is what breaks. Must
            # match add_app_vhosts.sh exactly: the two lists are compared,
            # and a name on one and not the other fails the pre-flight.
            case "$host" in
                *.*.*) request_cert "$host" "" ;;
                *.*)   request_cert "$host" "www.$host" ;;
            esac
        fi
    done
done < <(conf_rows)

# -----------------------------------------------------------------------------
# Deprecated domains. They only 301, but a redirect still has to be served over
# HTTPS or the browser refuses before it ever sees the redirect.
#
# www is included on the same certificate: a deprecated domain almost always has
# a www record too, and a second certificate for one name is a wasted rate-limit
# slot.
# -----------------------------------------------------------------------------
# A deprecated domain redirects to the live site, so it belongs to the live
# environment and is skipped when a run is narrowed to something else.
DEPRECATED="$(conf_get DEPRECATED_DOMAINS "")"
_want_deprecated=0
for p in "${PUBLISH_ENVS[@]}"; do
    [ "$p" = "$DEFAULT_PUBLISH" ] && _want_deprecated=1
done
[ "$_want_deprecated" -eq 0 ] && DEPRECATED=""

if [ -n "$DEPRECATED" ]; then
    IFS=',' read -r -a dep_list <<< "$DEPRECATED"
    for dom in "${dep_list[@]}"; do
        dom="$(trim "$dom")"
        [ -z "$dom" ] && continue
        request_cert "$dom" "www.$dom"
    done
fi

# -----------------------------------------------------------------------------
# Mail. Dovecot and Postfix present a certificate too, and until 2026-09-03
# nothing asked for one: the loop above skips mailbox rows, so the lineage they
# were pointed at only existed while some website row happened to carry the same
# apex. Deleting that row pruned the lineage and stopped Dovecot dead.
#
# One name per mail domain, mail.<domain>, on its own lineage, so it never
# collides with the website certificate for the same apex.
#
# Mail has no environments: there is one mail server, so this runs only when the
# default environment is being published.
# -----------------------------------------------------------------------------
_want_mail=0
for p in "${PUBLISH_ENVS[@]}"; do
    [ "$p" = "$DEFAULT_PUBLISH" ] && _want_mail=1
done

if [ "$_want_mail" -eq 1 ]; then
    MAIL_DOMAINS=""
    while IFS='|' read -r type name port path sub _rest; do
        _trim type "$type"
        _trim sub "$sub"
        [ "$type" = "mailbox" ] || continue
        if [ -z "$sub" ] || [ "$sub" = "-" ]; then sub="$BASE_DOMAIN"; fi
        [ -z "$sub" ] && continue
        case " $MAIL_DOMAINS " in
            *" $sub "*) ;;
            *) MAIL_DOMAINS="$MAIL_DOMAINS $sub" ;;
        esac
    done < <(conf_rows)

    for dom in $MAIL_DOMAINS; do
        request_cert "mail.$dom" ""
        # webmail.<domain> is a browser reading the same mailboxes, so it is one
        # name per mail domain exactly as mail.<domain> is. Separate lineages:
        # Dovecot and Apache are restarted by different things, and a shared
        # certificate makes one of them the reason the other reloads.
        # Only where something serves it: add_app_vhosts.sh publishes the name
        # only when Roundcube is installed, and a certificate for a name nothing
        # answers on spends a rate limit for nothing.
        if [ -d "$(conf_get WEBMAIL_ROOT /var/lib/roundcube/public_html)" ]; then
            request_cert "webmail.$dom" ""
        fi
    done
fi

# Every name published by a generator this script does NOT already duplicate,
# admin.<domain> being the first of them. Asked rather than derived: the rule
# deciding which domains get one belongs to the script that writes the vhost,
# and a copy of it here is a copy that drifts.
#
# --except add_app_vhosts.sh because the website and application names above
# are this script's own second derivation of that one, kept deliberately so
# either stays runnable alone; check_generators_agree.sh is the guard on it.
#
# Only where a vhost says so, so a certificate is never spent on a name
# nothing answers on. If the lister is missing, nothing extra is requested
# rather than the whole certificate step failing: an admin page with no
# certificate is served on plain HTTP and says so, which is a smaller problem
# than no certificates at all.
#
# `[ -n "$h" ] && request_cert ...` was the shape here, and as the LAST command
# of this function one blank line from the lister returned 1 and killed the
# whole certificate run silently, under set -e, with no message.
if [ -f "$SCRIPT_DIR/list_served_hostnames.sh" ]; then
    while read -r _ahost; do
        [ -n "$_ahost" ] || continue
        request_cert "$_ahost" ""
    done < <(SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/list_served_hostnames.sh" \
                 --for certs --except add_app_vhosts.sh 2>/dev/null || true)
fi || true
}

# =============================================================================
# Rehearse everything, then issue nothing unless all of it passed.
#
# The per-hostname staging test that already existed protects one name at a
# time, so a run could issue the first ten for real and fail on the eleventh,
# leaving the set half done and the rate limit half spent. Rehearsing the whole
# set first makes it all or nothing: a single failure anywhere means no
# production request is made at all.
#
# Skipped when the run is a rehearsal in the first place, which would otherwise
# do the same work twice for no answer.
# =============================================================================
# =============================================================================
# What certbot already holds, asked ONCE.
#
# This used to run inside the per-hostname check, so fifteen hostnames paid for
# the same answer fifteen times, at about a second each. It cannot change while
# this script runs, and the silence it caused was the gap after the address
# lines where nothing appeared to be happening.
# =============================================================================
# Not asked in LIST_HOSTS mode. What certbot already holds decides whether a
# name is requested, and LIST_HOSTS answers the different question of which
# names this config names at all. It was several seconds of every pre-flight,
# for an answer that mode never reads.
COVERED_NAMES=""
if [ "$LIST_HOSTS" != "1" ]; then
    printf "\033[34m🔧 Asking certbot what it already holds...\033[0m" >&2
    COVERED_NAMES="$(certbot certificates 2>/dev/null \
        | sed -n 's/^[[:space:]]*Domains:[[:space:]]*//p' | tr ' ' '\n')"
    redraw "\r\033[K" >&2
    _held="$(printf '%s\n' "$COVERED_NAMES" | grep -c . || true)"
    print_success "certbot holds ${_held} name(s) already."
fi

if [ "${CERT_DRY_RUN:-0}" != "1" ]; then
    print_header "Rehearsal"
    print_status "Every hostname is tried against staging first. Nothing real is"
    print_status "requested unless all of them pass."

    CERT_DRY_RUN=1
    SKIP_PER_HOST_STAGING=1
    request_all_hosts
    CERT_DRY_RUN=0

    if [ ${#FAILED[@]} -gt 0 ]; then
        echo ""
        print_error "${#FAILED[@]} hostname(s) failed the rehearsal, so nothing was requested for real:"
        for f in "${FAILED[@]}"; do print_error "  - $f"; done
        print_action "No production rate limit was spent. Fix the cause and run this again."
        exit 1
    fi

    print_success "${#ISSUED[@]} hostname(s) rehearsed cleanly. Requesting them for real."
    ISSUED=()
    ALREADY=()
    NO_DNS_RECORD=()
    NO_VHOST_YET=()
    FAILED=()
fi

request_all_hosts

echo ""
# Grouped under the registered domain and numbered, because fifteen hostnames on
# one line is a wall nobody reads, and the thing you look for is which domain a
# name belongs to.
print_hostname_tree() {
    local -n _list="$1"
    local domain last_domain="" n=0 name line
    # Sorted on the registered domain first, then the name, so each domain
    # appears once with its own names under it. Sorting the hostnames alone
    # interleaves them and prints a domain heading several times.
    while IFS=$'\t' read -r domain _apex name; do
        [ -z "$name" ] && continue
        if [ "$domain" != "$last_domain" ]; then
            printf "\033[36m  %s\033[0m\n" "$domain"
            last_domain="$domain"
        fi
        n=$((n + 1))
        if [ "$name" = "$domain" ]; then
            printf "\033[32m   %2d. └ (the domain itself)\033[0m\n" "$n"
        else
            printf "\033[32m   %2d. └ %s\033[0m\n" "$n" "${name%.$domain}"
        fi
    done < <(printf '%s\n' "${_list[@]}" \
             | awk -F. 'NF{d=$(NF-1)"."$NF; print d"\t"($0==d?0:1)"\t"$0}' \
             | sort -k1,1 -k2,2n -k3,3)
}

if [ ${#ISSUED[@]} -gt 0 ]; then
    if [ "${CERT_DRY_RUN:-0}" = "1" ]; then
        print_success "Staging certificates, not trusted by browsers (${#ISSUED[@]}):"
    else
        print_success "Issued (${#ISSUED[@]}):"
    fi
    print_hostname_tree ISSUED
    [ "${CERT_DRY_RUN:-0}" = "1" ] && \
        print_action "Set MACHINE_IS_LIVE = yes for certificates that browsers trust."
fi

if [ ${#ALREADY[@]} -gt 0 ]; then
    print_success "Already covered, renewal is certbot.timer's job (${#ALREADY[@]}):"
    print_hostname_tree ALREADY
fi

if [ ${#NO_VHOST_YET[@]} -gt 0 ]; then
    print_info "Certificate requested, but no vhost serves it yet: ${NO_VHOST_YET[*]}"
    print_action "Run add_app_vhosts.sh to put them into use."
fi

# Reported, not refused. Every one of these was still requested: DNS-01 reads a
# TXT record and never needs an address record. It is here because a name that
# has stopped resolving is usually one of two things worth acting on, and
# neither announces itself anywhere else.
if [ ${#NO_DNS_RECORD[@]} -gt 0 ]; then
    print_info "No address record, requested anyway:"
    for entry in "${NO_DNS_RECORD[@]}"; do
        print_info "  - $entry"
    done
    print_info "Either the record is not created yet, or the domain has lapsed."

    # YELLOW ONLY WHEN A HUMAN IS ACTUALLY NEEDED. Every name above was
    # requested and issued, so a record that has simply not propagated needs
    # nobody. The one case that does is a name in DEPRECATED_DOMAINS: that is a
    # config line somebody has to delete, and nothing else here notices.
    for entry in "${NO_DNS_RECORD[@]}"; do
        _dep_hit=0
        if [ -n "$DEPRECATED" ]; then
            # Comma separated in the config, so a whitespace split would never
            # match. Trimmed the same way the request loop trims it.
            printf '%s' "$DEPRECATED" | tr ',' '\n' \
                | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
                | grep -qxF "$entry" && _dep_hit=1
        fi
        if [ "$_dep_hit" -eq 1 ]; then
            print_action "$entry is in DEPRECATED_DOMAINS and no longer resolves."
            print_action "  Remove it from $SITES_CONF and rerun add_app_vhosts.sh to drop its redirect."
        fi
    done
fi

# -----------------------------------------------------------------------------
# Prove renewal works, rather than assuming the timer is enough.
#
# add_certbot.sh enables and starts certbot.timer, which is necessary and not
# sufficient: the timer firing proves nothing about whether the renewal would
# succeed. Each certificate's method is saved in /etc/letsencrypt/renewal/, so
# `certbot renew --dry-run` replays exactly what will happen in 60 days,
# against staging.
#
# This is the check that catches a webroot that has moved, a vhost that no
# longer serves /.well-known/, or a hostname whose DNS has changed. Without it
# the first sign of trouble is a browser warning on the day a certificate
# expires.
# -----------------------------------------------------------------------------
if [ "${CERT_DRY_RUN:-0}" != "1" ] && certbot certificates 2>/dev/null | grep -q "Certificate Name:"; then
    echo ""
    # Watched, never killed, and it names the certificate it is on.
    #
    # Under DNS-01 this replays the whole challenge for every certificate on the
    # machine: write a TXT record, wait for the nameservers, delete it. Fifteen
    # of those take minutes at near zero CPU, which looks exactly like a hang.
    print_status "Testing renewal for every certificate on this machine..."
    print_status "Each one replays its DNS challenge, so this takes minutes."
    RENEW_LOG="$(mktemp)"

    # certbot names each certificate as it starts on it, and the renewal
    # directory says how many there are, so this is countable rather than a
    # guess. In debug mode the output is streamed instead: a bar is worse than
    # the real thing when you are trying to see why something failed.
    _total="$(find /etc/letsencrypt/renewal -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)"
    [ "$_total" -eq 0 ] && _total=1

    if [ "$DEBUG_MODE" = "1" ]; then
        certbot renew --dry-run 2>&1 | tee "$RENEW_LOG"
        _renew_rc=${PIPESTATUS[0]}
        _started=$SECONDS
    else
        certbot renew --dry-run >"$RENEW_LOG" 2>&1 &
        _renew_pid=$!
        _spin='-\|/'
        _i=0
        _started=$SECONDS
        while kill -0 "$_renew_pid" 2>/dev/null; do
            _done="$(grep -c '^Processing /etc/letsencrypt/renewal/' "$RENEW_LOG" 2>/dev/null || echo 0)"
            [ "$_done" -gt "$_total" ] && _done="$_total"
            _now="$(sed -n 's|^Processing /etc/letsencrypt/renewal/\(.*\)\.conf$|\1|p' \
                    "$RENEW_LOG" 2>/dev/null | tail -n1)"

            _filled=$(( _done * 28 / _total ))
            _bar=""
            for _b in $(seq 1 28); do
                if [ "$_b" -le "$_filled" ]; then _bar="${_bar}█"; else _bar="${_bar}░"; fi
            done
            _i=$(( (_i + 1) % 4 ))

            redraw "\r\033[K\033[34m[%s] %s  %2d/%d  %3ds  %s\033[0m" \
                "$_bar" "${_spin:$_i:1}" "$_done" "$_total" \
                "$((SECONDS - _started))" "${_now:-starting}" >&2
            sleep 1
        done
        redraw "\r\033[K" >&2
        wait "$_renew_pid" && _renew_rc=0 || _renew_rc=$?
    fi
    if [ "$_renew_rc" -eq 0 ]; then
        print_success "Renewal test passed in $((SECONDS - _started))s. certbot.timer will keep these current."
    else
        print_error "Renewal test FAILED. These certificates will expire silently."
        print_info "Nothing is broken today: certificates last 90 days. Last 20 lines:"
        tail -n 20 "$RENEW_LOG"
        print_action "Full log: $RENEW_LOG"
        FAILED+=("renewal test")
    fi
    rm -f "$RENEW_LOG" 2>/dev/null || true

    if ! systemctl is-active --quiet certbot.timer 2>/dev/null; then
        print_info "certbot.timer is not active, so nothing will trigger a renewal."
        print_action "Start it: sudo systemctl enable --now certbot.timer"
    fi
fi

if [ ${#ISSUED[@]} -gt 0 ]; then
    echo ""
    print_action "Now run add_app_vhosts.sh again."
    print_action "It writes the :443 blocks, which it could not do before these"
    print_action "certificates existed. Until then the new names are HTTP only."
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Problems:"
    for entry in "${FAILED[@]}"; do
        print_error "  - $entry"
    done
    exit 1
fi

print_success "Site certificates configured."
