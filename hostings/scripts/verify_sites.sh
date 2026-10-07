#!/bin/bash
# =============================================================================
# Does every published site actually answer?
#
# One question, one script. Split out of maintain_services.sh on 2026-08-16,
# because the two questions were sharing an exit code: "does the machine match
# the config" and "does every site answer" are different, and a staging
# certificate makes the second false while the first is perfectly true.
#
# "Linux Install.docx" ends its certificate section with a list of sixteen URLs
# to open in a browser and confirm. That step is a learning, not ceremony:
# everything before it proves the config parses and the certificates exist, and
# none of it proves a visitor gets a page.
#
# Each hostname is forced to 127.0.0.1 with --resolve, so this tests what this
# machine controls: vhost routing, the certificate presented, the login, and the
# application answering behind it. It deliberately does NOT prove the site is
# reachable from the internet. Connecting to the public address from the machine
# itself goes out to the router and back, which needs NAT hairpinning and fails
# for reasons that have nothing to do with any of this.
#
# The certificate is NOT skipped with -k, except for a lineage issued by the
# staging server. A name whose certificate does not cover it is exactly what this
# is looking for; a staging certificate is untrusted on purpose, so without -k it
# times out and reports 000, which says nothing about whether the site serves.
# Those lines are labelled "(staging certificate)".
#
# Exits non-zero when a site did not answer. Callers that only applied a config
# should report that rather than fail on it.
#
# Usage:
#   ./verify_sites.sh
#   SITES_CONF=/path/to/hostings.conf ./verify_sites.sh
# =============================================================================

set -e

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

# Watch-only spinner: shows the command is alive but never signals it. Nothing
# here is safe to kill halfway, so there is no timeout and no SIGTERM.
#
# Silent when stdout is not a terminal. check_hostings.sh captures this output
# into the file the hosting manager displays, and carriage returns in a report
# are noise nobody can read.
show_spinner_watch_only() {
    local message="$1"
    shift
    if [ ! -t 1 ]; then "$@"; return $?; fi

    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    "$@" &
    local cmd_pid=$! tick=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
        redraw '\r\033[K\033[34m%s %s\033[0m' "${frames[tick % 10]}" "$message"
        tick=$((tick + 1))
        sleep 0.2 || { printf "\n\033[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\033[0m\n"; break; }
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    redraw '\r\033[K'
    return $exit_code
}

# Wrapped commands whose output is needed write it to a file, so the spinner
# keeps the terminal to itself.
probe_host() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
         --resolve "${1}:443:127.0.0.1" "https://${1}/" >"$2" 2>/dev/null || printf '' >"$2"
}

# For a staging certificate only. -k is normally exactly what must NOT be used
# here: a name whose certificate does not cover it is what this script looks for.
# A staging certificate is a different case: it is known to be untrusted, that is
# what staging means, and without -k the name times out and reports 000, which
# says nothing about whether the site serves.
probe_host_insecure() {
    curl -sk -o /dev/null -w '%{http_code}' --max-time 15 \
         --resolve "${1}:443:127.0.0.1" "https://${1}/" >"$2" 2>/dev/null || printf '' >"$2"
}

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

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
declare -A _CONF_CACHE=()
conf_get() {
    local key="$1" default="$2" value
    if [ -n "${_CONF_CACHE[$key]+set}" ]; then
        value="${_CONF_CACHE[$key]}"
    else
        value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # tr -d '\r': xargs does not strip a carriage return, and a value is
        # the last thing on its line, so a CRLF config leaves one in it.
        value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
        _CONF_CACHE[$key]="$value"
    fi
    echo "${value:-$default}"
}

conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# A field holding a single dash means empty. `| | |` cannot be counted by eye.
trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# Does this row exist in this environment? An empty Envs field means all of them.
row_in_env() {
    local list="$1" env="$2" e
    list="$(echo "$list" | xargs)"
    [ -z "$list" ] || [ "$list" = "-" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in "${_re[@]}"; do
        [ "$(echo "$e" | xargs)" = "$env" ] && return 0
    done
    return 1
}

# One place that decides what counts as yes. A value accepted in one script and
# rejected in another is the kind of inconsistency nobody finds quickly.
is_yes() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "${v,,}" in
        y|yes|true|1) return 0 ;;
        *)            return 1 ;;
    esac
}

# Is this row protected in this environment?
#
#   live:no, test:yes    per environment
#   yes / no             every environment
#
# An environment the row does not mention is protected, so a test copy cannot be
# published open by accident.
auth_in_env() {
    local spec="$1" env="$2" part k v
    spec="$(echo "$spec" | xargs)"

    case "$spec" in
        *:*) ;;
        *)   is_yes "$spec" && return 0 || return 1 ;;
    esac

    IFS=',' read -r -a _ae <<< "$spec"
    for part in ${_ae+"${_ae[@]}"}; do
        k="$(trim "${part%%:*}")"
        v="$(trim "${part#*:}")"
        if [ "$k" = "$env" ]; then
            is_yes "$v" && return 0 || return 1
        fi
    done

    [ "$env" = "$DEFAULT_ENV" ] && return 1
    return 0
}

# A machine with only panels (HomeRun) has no site to ask, and no BASE_DOMAIN.
if [ -z "$(conf_rows)" ]; then
    print_info "No site rows in $SITES_CONF, so there is no site to ask."
    exit 0
fi

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
if [ -z "$BASE_DOMAIN" ]; then
    print_error "No BASE_DOMAIN in $SITES_CONF"
    exit 1
fi

IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
DEFAULT_ENV="${ALL_ENVS[0]}"

# ONLY_ROWS narrows the asking to named rows, matched on the second column, so a
# two-tick edit does not wait on 26 hostnames of which 12 time out. Unset is
# every row. A name that is no row is ignored rather than fatal: this reports and
# never writes, and refusing to look at anything is the worse answer.
ONLY_ROWS="$(trim "${ONLY_ROWS:-}")"
declare -A _WANTED=()
if [ -n "$ONLY_ROWS" ]; then
    IFS=',' read -r -a _rw <<< "$ONLY_ROWS"
    for _r in ${_rw+"${_rw[@]}"}; do
        _r="$(trim "$_r")"
        [ -n "$_r" ] && _WANTED["$_r"]=1
    done
fi

IFS=',' read -r -a PUBLISH_ENVS <<< "$(conf_get PUBLISH_ENVS "$(conf_get ENVS live)")"
for i in "${!PUBLISH_ENVS[@]}"; do PUBLISH_ENVS[$i]="$(trim "${PUBLISH_ENVS[$i]}")"; done

# =============================================================================
# The check
# =============================================================================
# Which hostnames a certificate actually covers, asked once. A name with no
# certificate cannot answer HTTPS, and waiting curl's --max-time 15 to be told so
# was most of a 107 second apply: ten such names on this machine.
#
# Asked of certbot rather than worked out from the renewal filenames, because a
# lineage is named after its first -d and carries the rest as SANs:
# www.example.org has no file of its own.
#
# An empty map means the question could not be asked (no certbot, or not root),
# and then every name is probed exactly as before.
declare -A CERT_COVERS=()    # hostname -> the lineage that covers it
declare -A CERT_STAGING=()   # lineage  -> issued by the staging server
load_cert_coverage() {
    command -v certbot >/dev/null 2>&1 || return 0

    # Which lineages are staging, in one grep rather than one per name. The
    # renewal file records the ACME server that issued it, and the staging one
    # is not in any browser's or curl's trust store.
    local f
    for f in $(grep -l 'acme-staging' /etc/letsencrypt/renewal/*.conf 2>/dev/null); do
        f="${f##*/}"
        CERT_STAGING["${f%.conf}"]=1
    done

    # certbot prints a Certificate Name and then the Domains it covers, so the
    # two are read together: a lineage is named after its first -d and carries
    # the rest as SANs, and www.example.com has no file of its own.
    local line lineage="" name
    while IFS= read -r line; do
        case "$line" in
            *"Certificate Name:"*) lineage="${line##*: }" ;;
            *"Domains:"*)
                for name in ${line#*: }; do
                    [ -n "$name" ] && CERT_COVERS["$name"]="$lineage"
                done
                ;;
        esac
    done < <(certbot certificates 2>/dev/null | grep -E 'Certificate Name:|Domains:')
}

verify_sites() {
    local host expect code ok=0 bad=0 pending=0 nocert=0 staging tail

    if ! command -v curl >/dev/null 2>&1; then
        print_info "curl not found, so no site was verified."
        return 0
    fi

    print_header "Verify"
    print_status "Each hostname is resolved to 127.0.0.1, so this tests this machine only."

    while IFS='|' read -r type name port path sub datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
        type="$(trim "$type")"; name="$(trim "$name")"; sub="$(trim "$sub")"
        auth="$(echo "$auth" | xargs | tr '[:upper:]' '[:lower:]')"
        # A mailbox row's Subdomain is a mail domain, not a site to answer on.
        [ "$type" = "mailbox" ] && continue
        [ -z "$sub" ] && continue
        # A row switched off on purpose is not a site failing to answer. A
        # disabled website serves its under-construction page and would pass
        # anyway; a disabled application's vhost proxies to a stopped unit and
        # would be reported as broken every run.
        # The CR is stripped before xargs, which does not strip it. This is the
        # LAST field on the line, so a CRLF config reaches it, and "no\r" would
        # have put a deliberately disabled row back in the report.
        enabled="${enabled//$'\r'/}"
        enabled="$(echo "${enabled:-}" | sed 's/#.*//' | xargs | tr '[:upper:]' '[:lower:]')"
        if [ "$enabled" = "no" ]; then continue; fi
        if [ "${#_WANTED[@]}" -gt 0 ] && [ -z "${_WANTED[$name]:-}" ]; then
            continue
        fi

        for e in "${PUBLISH_ENVS[@]}"; do
            row_in_env "$rowenvs" "$e" || continue
            case "$type" in
                proxy) [ "$e" != "$DEFAULT_ENV" ] && continue ;;
            esac

            eu="$(echo "$e" | tr '[:lower:]' '[:upper:]')"
            prefix="$(conf_get "${eu}_HOST_PREFIX" "")"
            case "$sub" in
                @*) if [ -z "$prefix" ]; then host="$BASE_DOMAIN"
                    else
                        label="${sub#@}"
                        [ -n "$label" ] && host="${prefix}${label}.${BASE_DOMAIN}" || host="${prefix}${BASE_DOMAIN}"
                    fi ;;
                =*) if [ -z "$prefix" ]; then host="${sub#=}"; else host="${prefix%%-}.${sub#=}"; fi ;;
                *)  host="${prefix}${sub}.${BASE_DOMAIN}" ;;
            esac

            # A protected site answering 200 without asking would be the
            # failure worth catching, so the expectation is explicit.
            if auth_in_env "$auth" "$e"; then
                expect="401"
            else
                expect="2xx/3xx"
            fi

            # Not asked when no certificate covers it: the answer is known, and
            # it is the certificate step's business rather than this one's.
            if [ "${#CERT_COVERS[@]}" -gt 0 ] && [ -z "${CERT_COVERS[$host]:-}" ]; then
                printf "\033[33m  %-45s  no certificate yet, so it was not asked\033[0m\n" "$host"
                nocert=$((nocert+1))
                continue
            fi

            # A staging certificate is untrusted by design, so the question
            # becomes "does the site serve", asked with -k and labelled.
            # The lineage is read into a variable first: with no certificates
            # known at all the guard above does not run, and an empty subscript
            # is an error rather than a miss.
            staging=0
            lineage="${CERT_COVERS[$host]:-}"
            if [ -n "$lineage" ] && [ -n "${CERT_STAGING[$lineage]:-}" ]; then
                staging=1
            fi

            # curl prints 000 itself when it never got a response, so the
            # fallback only catches it printing nothing at all. It must not be
            # `|| echo 000`: that appended to what curl already printed. It must
            # also not be left off: a TLS failure exits non-zero and set -e ends
            # the run on the first unreachable host.
            probe_out="$(mktemp)"
            if [ "$staging" -eq 1 ]; then
                show_spinner_watch_only "Asking ${host}" probe_host_insecure "$host" "$probe_out" || true
            else
                show_spinner_watch_only "Asking ${host}" probe_host "$host" "$probe_out" || true
            fi
            code="$(cat "$probe_out")"
            rm -f "$probe_out"
            code="${code:-000}"
            [ "$staging" -eq 1 ] && tail="  (staging certificate)" || tail=""

            # A form login redirects, it does not send 401. mod_auth_form is
            # what every protected site here uses, so 302 is the lock working
            # and 401 would mean the browser popup this setup removed.
            #
            # 503 and 404 say the vhost is right and the content is not there
            # yet: no dll deployed, or a document root that does not exist.
            # Worth seeing, not worth failing a run over.
            case "$code:$expect" in
                401:401|30[123]:401) printf "\033[32m  %-45s %s  locked, as configured%s\033[0m\n" "$host" "$code" "$tail"; ok=$((ok+1)) ;;
                2*:2xx/3xx|3*:2xx/3xx) printf "\033[32m  %-45s %s%s\033[0m\n" "$host" "$code" "$tail"; ok=$((ok+1)) ;;
                2*:401)             printf "\033[31m  %-45s %s  EXPECTED A LOGIN\033[0m\n" "$host" "$code"; bad=$((bad+1)) ;;
                503:*)              printf "\033[33m  %-45s %s  vhost fine, nothing deployed behind it\033[0m\n" "$host" "$code"; pending=$((pending+1)) ;;
                404:*)              printf "\033[33m  %-45s %s  vhost fine, no content at the document root\033[0m\n" "$host" "$code"; pending=$((pending+1)) ;;
                000:*)              printf "\033[31m  %-45s  no answer, or the certificate does not cover this name\033[0m\n" "$host"; bad=$((bad+1)) ;;
                *)                  printf "\033[31m  %-45s %s\033[0m\n" "$host" "$code"; bad=$((bad+1)) ;;
            esac
        done
    done < <(conf_rows)

    echo ""
    [ "$pending" -gt 0 ] && \
        print_info "$pending site(s) are served but have nothing behind them yet."
    # Reported, never failed on: a hostname with no certificate is a certificate
    # that has not been issued, which add_site_certificates.sh has already said
    # in its own output, with the reason.
    [ "$nocert" -gt 0 ] && \
        print_info "$nocert site(s) have no certificate yet and were not asked."

    if [ "$bad" -eq 0 ]; then
        print_success "$ok site(s) answered as configured."
    elif ! is_yes "$(conf_get MACHINE_IS_LIVE no)" && [ "$ok" -eq 0 ] && [ "$pending" -eq 0 ]; then
        # Only excused when NOTHING answered, which is what staging looks like:
        # no certificate exists, so TLS cannot complete for any name. Once some
        # names answer, the ones that do not have a real problem and the flag is
        # no longer the explanation.
        print_info "$bad site(s) did not answer over HTTPS."
        print_info "MACHINE_IS_LIVE = no and no certificate exists yet, so this is expected."
        print_action "Flip it after the drive swap."
        return 0
    else
        print_error "$bad site(s) did not. $ok were fine."
        print_info "A 000 usually means the certificate does not cover that hostname:"
        print_action "  sudo bash $SCRIPT_DIR/add_site_certificates.sh, then the vhost script again."
        return 1
    fi
    return 0
}

load_cert_coverage
verify_sites
exit $?
