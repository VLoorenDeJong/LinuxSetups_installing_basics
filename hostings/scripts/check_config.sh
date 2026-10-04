#!/bin/bash
# =============================================================================
# Can this config be applied on this machine?
#
# One question, one script. Split out of maintain_services.sh on 2026-08-16.
# It reads and reports; it changes nothing, so it is safe to run at any time.
#
# Two halves that are one concern. First: is the config internally sound, with
# no duplicate name, no duplicate port, no row pointing at a row that is not
# there. Second: does this machine have what that config needs, which is
# decided BY the first half. Splitting them would mean a second parser deciding
# what a row needs, and two parsers that disagree is the exact fault the
# generator cross-check exists to catch.
#
# Errors block, warnings do not. A duplicate port means the run cannot succeed.
# DNS that does not resolve yet is worth knowing while the rest of the run is
# still correct: if warnings blocked, a machine with one un-pointed record
# could never be configured at all.
#
# Usage:
#   ./check_config.sh
#   FLAGS_OUT=/tmp/flags ./check_config.sh
#
# FLAGS_OUT gets what the config was found to need, for a caller that has to
# act on it rather than read it. Working it out again elsewhere is what this
# script exists to prevent.
#
# Exits non-zero when the config cannot be applied.
# =============================================================================
set -e

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

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

FLAGS_OUT="${FLAGS_OUT:-}"
ONLY_ROWS="${ONLY_ROWS:-}"

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

# Resolve a row's Subdomain field into a hostname for one environment.
#
# Duplicated from add_app_vhosts.sh:501, which is the rule for this repo: every
# script stays runnable on a machine that has only that one file. This script
# cross-checks the generators, so a copy that drifts is reported rather than
# discovered.
#
#   demo        demo.BASE_DOMAIN, prefixed per environment
#   @           BASE_DOMAIN itself
#   =full.tld   a complete domain, BASE_DOMAIN is not appended
#   empty       no hostname, so nothing is published
_resolve_host() {
    local -n __h="$1"
    local __rs="$2" __rp="$3" __rl
    [ -z "$__rs" ] && return 1
    case "$__rs" in
        @*)
            if [ -z "$__rp" ]; then
                __h="$BASE_DOMAIN"
            else
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
                __h="${__rs#=}"
            else
                __h="${__rp%%-}.${__rs#=}"
            fi
            ;;
        *)  __h="${__rp}${__rs}.${BASE_DOMAIN}" ;;
    esac
    return 0
}

# One place that decides what counts as yes. Accepts y, yes, true and 1 in any
# case; everything else, including empty and a dash, is no. Written once rather
# than as a case pattern at each site, because a value accepted in one script
# and rejected in another is the kind of inconsistency nobody finds quickly.
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
# Duplicated verbatim from add_app_vhosts.sh, which is the rule for this
# repo: every script stays runnable on a machine that has only that one file.
# The duplication is safe because this script cross-checks the generators
# against each other, so a copy that drifts is reported rather than discovered.
#
#   live:no, test:yes    per environment
#   yes / no             every environment
#
# An environment the row does not mention is protected, so a test copy cannot be
# published open by accident.
auth_in_env() {
    local spec="$1" env="$2" part k v
    _trim spec "$spec"

    case "$spec" in
        *:*) ;;
        *)   is_yes "$spec" && return 0 || return 1 ;;
    esac

    IFS=',' read -r -a _ae <<< "$spec"
    for part in ${_ae+"${_ae[@]}"}; do
        _trim k "${part%%:*}"
        _trim v "${part#*:}"
        if [ "$k" = "$env" ]; then
            is_yes "$v" && return 0 || return 1
        fi
    done

    # This script calls the first environment DEFAULT_ENV where the generator
    # calls it DEFAULT_PUBLISH. Same value, different name, so the copy is not
    # quite verbatim after all.
    [ "$env" = "$DEFAULT_ENV" ] && return 1
    return 0
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

ERRORS=()
WARNINGS=()

err()  { ERRORS+=("$1"); }
warn() { WARNINGS+=("$1"); }

# A quoted setting value is taken literally by every reader of this file, so
# WEB_ROOT_TEST = "/srv/x" would create a directory whose name holds the quotes.
# The readers used to strip them through xargs, which also broke on an
# apostrophe; they no longer do, so the config is where this is caught.
while IFS= read -r _cl; do
    _cl="${_cl%%#*}"
    [[ "$_cl" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*[\"\'] ]] \
        && err "Setting ${BASH_REMATCH[1]} has a quoted value. Write it without quotes: the quotes become part of the value."
done < "$SITES_CONF"

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
# Demanded after the rows are counted: only rows build hostnames from it.

IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
for i in "${!ALL_ENVS[@]}"; do ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"; done
DEFAULT_ENV="${ALL_ENVS[0]}"

IFS=',' read -r -a PUBLISH_ENVS <<< "$(conf_get PUBLISH_ENVS "$(conf_get ENVS live)")"
for i in "${!PUBLISH_ENVS[@]}"; do PUBLISH_ENVS[$i]="$(trim "${PUBLISH_ENVS[$i]}")"; done

AUTH_USER_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
AUTH_SESSION_KEY_FILE="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"

AVAILABLE_DIR="/etc/apache2/sites-available"
UNIT_DIR="/etc/systemd/system"
GENERATED_MARK="from /etc/hostings/hostings.conf"


print_status "Config:       $SITES_CONF"
print_status "Environments: ${ALL_ENVS[*]}"
print_status "Publishing:   ${PUBLISH_ENVS[*]}"

# Checked here rather than left to the generators, so a typo stops the run
# before anything is written instead of after the units are done.
if [ -n "$ONLY_ROWS" ]; then
    IFS=',' read -r -a _rw <<< "$ONLY_ROWS"
    for _r in "${_rw[@]}"; do
        _r="$(trim "$_r")"
        [ -z "$_r" ] && continue
        awk -F'|' -v n="$_r" '
            /^[[:space:]]*#/ { next }
            NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                     if ($2 == n) found = 1 }
            END { exit !found }' "$SITES_CONF" \
            || err "--only-row names '$_r', which is no row in the config"
    done
    print_status "Rows:         $ONLY_ROWS (the report still covers all)"
fi

# =============================================================================
# 1. Validate the config completely, rather than discovering a bad row when the
#    loop reaches it. Half-applied config is the failure this prevents.
# =============================================================================
declare -A SEEN_NAME=()
declare -A SEEN_PORT=()
declare -A SEEN_PATH=()
# One hostname, one ENABLED row. Two rows for a customer is the point: a www_
# one serving files and an app_ one running a service, switched by ticking one
# and unticking the other. Two of them enabled at once is not a switch, it is
# two vhosts claiming the same ServerName, and Apache would answer with
# whichever it read first. The owner, 2026-09-10.
declare -A SEEN_HOST=()

# What is listening now, and which of our own units are up. A port held by one
# of our own running services is expected; anything else is a clash.
LISTENING_PORTS="$(ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un)"
# NOT --state=running alone. A unit that is still ACTIVATING already holds its
# port, and a unit that is DEACTIVATING has not let go of it yet, so either one
# left its own row reported as colliding with itself:
#
#   progress_example_net: port 8003 (live) is already held by another
#   process
#
# 2026-09-11. That refused a whole publish seconds after the same row's unit had
# been started by the apply, and the rows being saved at that moment never
# reached the branch. Re-running the check once the unit had settled passed with
# exit 0 on the identical config, which is what proved it a race rather than a
# collision.
RUNNING_UNITS="$(systemctl list-units 'app-*' --state=running,activating,deactivating --no-legend 2>/dev/null | awk '{print $1}')"
EPHEMERAL_LOW="$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)"
declare -A ROW_TYPE=()
NEEDS_AUTH=0
NEEDS_CERT=0
NEEDS_DOTNET=0
ROW_COUNT=0

# c15 is Enabled and c16 is Owner, neither of which a row written before them
# has. c17 is
# read only so an over-long row can be detected: anything landing in it means
# the row has more fields than the format allows.
while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17; do
    ROW_COUNT=$((ROW_COUNT + 1))

    _trim type "$c1"; _trim name "$c2"; _trim port "$c3"
    _trim path "$c4"; _trim sub "$c5"; _trim datasource "$c6"
    _trim options "$c7"; _trim auth "$c8"; auth="${auth,,}"
    _trim repo "$c9"
    # Read here rather than further down: the port check needs it, and a
    # variable assigned later still holds the PREVIOUS row's value.
    _trim rowenvs "$c11"; _trim authusers "$c12"; _trim repomode "$c13"
    _trim runtime "$c14"; runtime="${runtime,,}"

    label="${name:-row $ROW_COUNT}"

    # Field count. A row with the wrong number silently shifts every value one
    # column left or right, which is how AuthProtected once landed in the
    # options field and would have been parsed as a setting.
    if [ -n "$c17" ]; then
        err "$label: more than sixteen fields"
    elif [ -z "$c12" ]; then
        err "$label: fewer than twelve fields (RepoMode may be a dash). Use a dash for an empty one."
    fi

    # Enabled, and only three spellings are allowed. A typo here would read as
    # enabled everywhere, so a row meant to be off would quietly stay on.
    _trim enabled "$c15"; enabled="${enabled,,}"
    case "$enabled" in
        ""|-|yes|no) ;;
        *) err "$label: Enabled is '$enabled', which is not yes, no or a dash" ;;
    esac

    # Owner: which account this row belongs to, or a dash for nobody. Item 105.
    #
    # It is NOT checked against the password file. A row whose owner has been
    # deleted stays valid and simply belongs to nobody the page can show, which
    # is the safe direction: refusing the whole apply because an account was
    # removed would take every OTHER row down with it.
    #
    # This is the LAST field on the line now, so it is the one a CRLF config
    # reaches. The CR is stripped before the charset test, or every owner would
    # read as invalid the moment somebody saved the file from Windows.
    _trim owner "$c16"; owner="${owner//$'\r'/}"
    case "$owner" in
        ""|-) ;;
        *[!A-Za-z0-9._-]*) err "$label: Owner is '$owner', which is not a username" ;;
    esac

    # Checked here rather than by whatever creates the repository, so a typo is
    # caught before anything is written rather than halfway through creating one.
    case "${repomode,,}" in
        ""|-|private|portfolio|opensource) ;;
        *) err "$label: RepoMode '$repomode' is not private, portfolio or opensource" ;;
    esac

    # The application type, and what it implies. Checked here so a typo is a
    # sentence in the drift report rather than a unit that will not start.
    if [ "$type" = "app" ]; then
        # dotnet8, dotnet10: the major the project is CREATED against, so a
        # machine with two SDKs does not silently seed against the newest one.
        # After the first build the truth is the build's own runtimeconfig.json,
        # which is what the console's Runs on column reads; this number only
        # decides what "dotnet new" targets.
        case "$runtime" in
            ""|-|dotnet|dotnet[0-9]|dotnet[0-9][0-9]) NEEDS_DOTNET=1 ;;
            # Uno with Server (item 139): a .NET dll like any other, built in the
            # WebAssembly builder container because its client half is WASM.
            uno)
                NEEDS_DOTNET=1
                { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; } || \
                    err "$label: is an Uno application, which is built in a container, and Docker is not usable. Run: sudo bash LinuxBasics/install_scripts/check_docker.sh"
                ;;
            # Runs as a container built from the repository's Dockerfile (item
            # 140). docker_node and docker_python (item 141) run identically
            # and differ only in what a new repository is seeded with.
            docker|docker_node|docker_python)
                { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; } || \
                    err "$label: is a Docker application and Docker is not usable. Run: sudo bash LinuxBasics/install_scripts/check_docker.sh"
                ;;
            upstream:*)
                { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; } || \
                    err "$label: is an upstream package, which runs as a container, and Docker is not usable. Run: sudo bash LinuxBasics/install_scripts/check_docker.sh"
                [ -f "$REPO_ROOT/hostings/upstream/${runtime#upstream:}/recipe.conf" ] || \
                    err "$label: runs upstream package '${runtime#upstream:}', and there is no upstream/${runtime#upstream:}/recipe.conf"
                ;;
            node)
                # NAME THE FIX. This used to say there was no add_node.sh and
                # to install node by hand, which was true until 2026-09-05 and
                # is the kind of sentence that outlives its reason.
                command -v node >/dev/null 2>&1 || \
                    err "$label: is a Node application but node is not installed. Run: sudo bash LinuxBasics/install_scripts/add_node.sh"
                case "$path" in
                    *.js) ;;
                    *) err "$label: is a Node application, so Path must end in .js, not '$path'" ;;
                esac
                ;;
            angular|vue)
                err "$label: '$runtime' builds to static files, so it is a website row pointed at the build output, not an app"
                ;;
            *) err "$label: unknown application type '$runtime'. Expected dotnet, node, uno, docker, docker_node, docker_python or upstream:<package>." ;;
        esac
    elif [ "$type" = "website" ]; then
        # A WEBSITE ROW USES THE SAME FIELD FOR ITS PLATFORM, and that is what
        # decides which project seed_site_index.sh writes into a new repository.
        #
        # The field is reused rather than a fifteenth added, because the config
        # already carries fourteen and a website row never had an application
        # type to conflict with. Empty or '-' is the placeholder page, which is
        # every row written before 2026-09-05.
        #
        # An npm platform needs npm on the machine that BUILDS, which is this
        # one. Refused here rather than three minutes into a Jenkins build.
        case "${runtime,,}" in
            ""|-|html) ;;
            # PHP has no build step: Apache hands the file to the FPM pool per
            # request. What it needs is the SOCKET, and the php binary being
            # present says nothing about whether Apache can run a .php file.
            # Without it Apache serves the source, so a site would publish its
            # own code rather than fail visibly.
            php)
                ls /run/php/php*-fpm.sock >/dev/null 2>&1 || \
                    err "$label: is a PHP site and there is no php-fpm socket, so Apache would serve its source as text. Run: sudo apt install php-fpm"
                ;;
            uno)
                { command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; } || \
                    err "$label: is an Uno site, which is built in a container, and Docker is not usable. Run: sudo bash LinuxBasics/install_scripts/check_docker.sh"
                ;;
            vue|react|svelte|angular)
                command -v npm >/dev/null 2>&1 || \
                    err "$label: is a $runtime site and npm is not installed, so it cannot be built. Run: sudo bash LinuxBasics/install_scripts/add_node.sh"
                ;;
            dotnet|node|java)
                err "$label: '$runtime' is an application type. A website row's type is its front-end platform: html, php, vue, react, svelte, angular or uno."
                ;;
            wordpress)
                err "$label: WordPress is deliberately not supported. Its content lives in a database and wp-content rather than in git, so a rebuild would give an empty site. Decided 2026-09-06."
                ;;
            *)
                err "$label: unknown website platform '$runtime'. Expected html, php, vue, react, svelte, angular or uno."
                ;;
        esac
    elif [ -n "$runtime" ] && [ "$runtime" != "-" ]; then
        err "$label: only an app or website row has a type, but this $type row says '$runtime'"
    fi

    case "$type" in
        app)              ;;
        website|php|docroot)  ;;
        proxy)                ;;
        # A mailbox has no unit and no vhost, so this script only checks the row
        # is sane. add_mail_store.sh is what acts on it.
        mailbox)              ;;
        *) err "$label: unknown ServiceType '$type'. Expected app, website, proxy or mailbox." ;;
    esac
    ROW_TYPE["$name"]="$type"

    [ -z "$name" ] && err "row $ROW_COUNT: no ApplicationName"

    # A NAME BECOMES A FILENAME, so a space in it is not a style question.
    # `test 11` produced the unit `app-test 11.service`, which systemd cannot
    # have, and the row list then handed `test11` to ONLY_ROWS and stopped the
    # whole apply with "ONLY_ROWS names 'test11', which is no row". Item 96,
    # 2026-09-08, and the drawer's own hint has said "Lowercase, underscores, no
    # spaces" the whole time with nothing enforcing it.
    #
    # A mailbox name is a local part, which has its own rules and is checked
    # where the address is built, so this is the same set minus the case rule.
    case "$name" in
        *[!A-Za-z0-9._-]*)
            err "$label: '$name' has a character that cannot be in a unit name or a vhost filename. Letters, digits, dot, underscore and hyphen only."
            ;;
    esac

    # A mailbox has no unit and no vhost, so info@one.tld and info@two.tld do not
    # collide the way two apps named "info" would. Key it by local part AND
    # domain: two info@one.tld are still a real duplicate, one per domain is not.
    if [ "$type" = "mailbox" ]; then
        # RESOLVED domain, not the raw field. A mailbox line may write the base
        # domain either way, '-' or the name itself, and both deliver to the
        # same address. Keyed raw, contact@- and contact@example.com were two
        # different keys, so a genuine duplicate passed this check and was
        # applied. Seen on 2026-09-03, published by the console itself.
        _mbox_dom="$sub"
        if [ -z "$_mbox_dom" ] || [ "$_mbox_dom" = "-" ]; then
            _mbox_dom="$BASE_DOMAIN"
        fi
        seen_key="mailbox:$name@$_mbox_dom"
    else
        seen_key="$name"
    fi
    if [ -n "${SEEN_NAME[$seen_key]:-}" ]; then
        err "$label: duplicate ApplicationName. Unit and vhost names would collide."
    fi
    SEEN_NAME["$seen_key"]=1

    # One hostname, one ENABLED row, per environment. A disabled row is skipped
    # on purpose: holding a second row switched off, ready to take over, is the
    # whole point of the pair.
    #
    # A mailbox has no vhost, and a proxy names a service we do not publish a
    # document root for, so neither can collide this way.
    if [ "$enabled" != "no" ] && [ "$type" != "mailbox" ] && [ -n "$sub" ]; then
        for e in "${ALL_ENVS[@]}"; do
            row_in_env "$rowenvs" "$e" || continue
            [ "$type" = "proxy" ] && [ "$e" != "$DEFAULT_ENV" ] && continue
            _conf_get _hp "${e^^}_HOST_PREFIX" ""
            _resolve_host _rh "$sub" "$_hp" || continue
            if [ -n "${SEEN_HOST[$_rh]:-}" ]; then
                err "$label: $_rh ($e) is already served by ${SEEN_HOST[$_rh]}. Two enabled rows cannot answer on one hostname: switch one of them off."
            fi
            SEEN_HOST["$_rh"]="$label"
        done
    fi

    # One folder, one app. Two rows on one Path share the published files and
    # the settings file, so one of them runs with the other's settings.
    # Measured 2026-10-04: ProgressApp ran with testcust2_progress's backup path.
    # Same repository is fine; same folder is not. A Dockerfile names a file in
    # each row's own clone, so it cannot collide.
    if [ "$type" = "app" ] && [ -n "$path" ] && [ "$path" != "-" ] && [ "$path" != "Dockerfile" ]; then
        for e in "${ALL_ENVS[@]}"; do
            row_in_env "$rowenvs" "$e" || continue
            if [ -n "${SEEN_PATH[$e:$path]:-}" ]; then
                err "$label: Path $path ($e) is already used by ${SEEN_PATH[$e:$path]}. Another instance of the same repository is fine, but it needs its own folder, for example ${name}/$(basename "$path")."
            fi
            SEEN_PATH["$e:$path"]="$label"
        done
    fi

    # Ports, across every environment. 5205 and a dev offset of 1000 means 6205
    # is taken too, and a collision only shows up as one app refusing to start.
    if [ -n "$port" ]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            err "$label: Port '$port' is not a number"
        else
            for e in "${ALL_ENVS[@]}"; do
                # Only environments this row exists in. Jenkins is live-only, so
                # computing its test port invented a clash with a real row.
                row_in_env "$rowenvs" "$e" || continue
                # A proxy row is one service however many environments exist.
                [ "$type" = "proxy" ] && [ "$e" != "$DEFAULT_ENV" ] && continue

                eu="${e^^}"
                _conf_get off "${eu}_PORT_OFFSET" 0
                p=$((port + off))
                if [ -n "${SEEN_PORT[$p]:-}" ]; then
                    err "$label: port $p ($e) already used by ${SEEN_PORT[$p]}"
                fi
                SEEN_PORT[$p]="$label"

                # Also check against what is actually listening. Two rows
                # clashing is caught above; a row clashing with MySQL is not,
                # and only shows up as a unit that will not start.
                # A proxy row describes a service we do not manage, so its port
                # being held is the normal state, not a collision.
                if [ -n "${LISTENING_PORTS:-}" ] && [ "$type" != "proxy" ] \
                    && ! echo "$RUNNING_UNITS" | grep -q "app-${name}"; then
                    if echo "$LISTENING_PORTS" | grep -qx "$p"; then
                        err "$label: port $p ($e) is already held by another process"
                    fi
                fi

                # Outgoing connections use this range, so a service here can
                # find its port taken before it starts.
                if [ -n "${EPHEMERAL_LOW:-}" ] && [ "$p" -ge "$EPHEMERAL_LOW" ]; then
                    warn "$label: port $p ($e) is inside the ephemeral range ($EPHEMERAL_LOW+)"
                fi
            done
        fi
    fi

    # THE REPOSITORY FIELD WAS NEVER CHECKED AT ALL. `not-a-url` and
    # `ftp://evil/x.git` both passed, and the first anybody heard of it was a
    # red Jenkins build failing at the clone, which reads as a pipeline fault
    # rather than a typo in a row.
    #
    # Shape only. Whether the repository EXISTS is provision_repo.sh's question,
    # it needs a token and the network, and this script is meant to run on a
    # machine with neither.
    #
    # `new` is the magic word for "create it on the next apply", and `-` or
    # empty is a row with no repository at all. Both are left alone.
    case "$repo" in
        ""|-|new) ;;
        https://*.git|git@*:*.git) ;;
        https://*|git@*:*)
            err "$label: Repository '$repo' does not end in .git, so the clone would fail" ;;
        *)
            err "$label: Repository '$repo' is not a clone URL. Expected https://host/owner/name.git or git@host:owner/name.git, or the word new" ;;
    esac

    case "$type" in
        app)
            [ -z "$port" ] && err "$label: app needs a Port"
            # An upstream package is an image, not a file, so it has no path.
            [ -z "$path" ] && [[ "$runtime" != upstream:* ]] && err "$label: app needs a DllPath"
            [[ "$path" == /* ]] && err "$label: DllPath must be relative to APP_ROOT, not absolute"
            [[ "$path" == ".." || "$path" == */../* || "$path" == ../* || "$path" == */.. ]] && \
                err "$label: DllPath may not climb out of APP_ROOT with .."
            ;;
        website|php|docroot)
            [ -z "$path" ] && err "$label: a website needs a document root folder in Path"
            # Relative, like an app row's dll path. An absolute path would
            # pin the row to one environment, which is exactly what WEB_ROOT_<ENV>
            # exists to avoid.
            [[ "$path" == /* ]] && err "$label: a website's Path must be relative to WEB_ROOT, not absolute"
            # RELATIVE IS NOT THE SAME AS INSIDE, and the absolute test alone
            # read as if it were. `../../etc` is relative, passed every check,
            # and would have given Apache a DocumentRoot outside WEB_ROOT: the
            # row would publish whatever it landed on over HTTPS.
            #
            # Found 2026-09-06 by typing it into the drawer, which accepted it,
            # and then into this validator, which also accepted it. The absolute
            # form was refused by both, which is what made the gap easy to miss.
            [[ "$path" == ".." || "$path" == */../* || "$path" == ../* || "$path" == */.. ]] && \
                err "$label: a website's Path may not climb out of WEB_ROOT with .."
            ;;
        proxy)
            [ -z "$port" ] && err "$label: proxy needs a Port"
            ;;
        mailbox)
            # Rejected here rather than by Postfix at delivery time, where the
            # bounce is the first anyone hears of it.
            [[ "$name" =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] \
                || err "$label: mailbox name is not a usable local part (lowercase, digits, . _ -)"
            [ -n "$port" ] && err "$label: a mailbox has no Port"
            [ -n "$path" ] && err "$label: a mailbox has no Path"
            ;;
    esac

    # Hostname rules. An underscore is invalid in a hostname: some resolvers
    # accept it, certificate authorities and browsers do not.
    # Both are written unquoted into vhosts and ExecStart, so a space or a quote
    # would break Apache for every site or hand dotnet extra arguments.
    [[ -z "$path" || "$path" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || err "$label: Path '$path' may hold only letters, digits, dot, underscore, hyphen and /"
    [[ -z "$sub" || "$sub" == "@" || "$sub" =~ ^=?[A-Za-z0-9.-]+$ ]] \
        || err "$label: Domain '$sub' may hold only letters, digits, dot and hyphen"

    if [ -n "$sub" ]; then
        NEEDS_CERT=1
        case "$sub" in
            @) ;;
            *_*) err "$label: Subdomain '$sub' contains an underscore. Use hyphens." ;;
            -*|*-) err "$label: Subdomain '$sub' starts or ends with a hyphen" ;;
        esac
    fi

    if [ -n "$datasource" ]; then
        case "$datasource" in
            =*) ;;
            "$name") err "$label: lists itself as its own DataSource" ;;
            *) DATASOURCE_REFS+=("$name:$datasource") ;;
        esac
    fi

    if [ -n "$options" ]; then
        IFS=';' read -r -a pairs <<< "$options"
        for p in "${pairs[@]}"; do
            _trim p "$p"
            [ -z "$p" ] && continue
            [[ "$p" != *=* ]] && err "$label: option '$p' is not KEY=VALUE"
        done
    fi

    # Either one answer, or one per environment: "live:no, test:yes".
    case "${auth,,}" in
        y|yes|true|1)        NEEDS_AUTH=1 ;;
        ""|-|n|no|false|0)   ;;
        *:*)
            IFS=',' read -r -a _ap <<< "$auth"
            for _part in "${_ap[@]}"; do
                _trim _k "${_part%%:*}"
                _trim _v "${_part#*:}"
                if ! printf '%s\n' "${ALL_ENVS[@]}" | grep -qx "$_k"; then
                    err "$label: AuthProtected names environment '$_k', which is not in ENVS"
                fi
                case "$_v" in
                    y|yes|true|1) NEEDS_AUTH=1 ;;
                    n|no|false|0) ;;
                    *) err "$label: AuthProtected '$_k:$_v' is not yes or no" ;;
                esac
            done
            ;;
        *) err "$label: AuthProtected '$auth' is not yes, no, or per environment" ;;
    esac

    # Envs must name environments that exist, or the row silently generates
    # nothing at all and the only symptom is a missing site.
    # rowenvs is read near the top, where the port check needs it.
    if [ -n "$rowenvs" ]; then
        IFS=',' read -r -a _rl <<< "$rowenvs"
        for re in "${_rl[@]}"; do
            _trim re "$re"
            [ -z "$re" ] && continue
            known=0
            for e in "${ALL_ENVS[@]}"; do
                [ "$e" = "$re" ] && known=1
            done
            [ "$known" -ne 1 ] && err "$label: Envs names '$re', which is not in ENVS"
        done
    fi

    # A Branch override is a git branch name, not an environment. Catching a
    # typo here beats a Jenkins job that checks out nothing.
    _trim rowbranch "$c10"
    case "$rowbranch" in
        *[[:space:]]*) err "$label: Branch '$rowbranch' contains whitespace" ;;
    esac
done < <(conf_rows)

# Checked after the loop, because a DataSource may legitimately name a row that
# appears later in the file
for ref in "${DATASOURCE_REFS[@]:-}"; do
    [ -z "$ref" ] && continue
    who="${ref%%:*}"; target="${ref#*:}"
    [ -z "${SEEN_NAME[$target]:-}" ] && err "$who: DataSource '$target' names no row in the config"
done

# Rows are not compulsory: a LAN-only machine may serve machine pages and
# nothing else. A config with neither has nothing to apply.
PANEL_COUNT="$(grep -cE '^[[:space:]]*PANEL[[:space:]]*=' "$SITES_CONF" 2>/dev/null || true)"
if [ "$ROW_COUNT" -eq 0 ] && [ "${PANEL_COUNT:-0}" -eq 0 ]; then
    err "No rows and no machine pages in $SITES_CONF"
fi
[ "$ROW_COUNT" -gt 0 ] && [ -z "$BASE_DOMAIN" ] && err "No BASE_DOMAIN in $SITES_CONF, which the rows need for their hostnames"

# =============================================================================
# 2. Can this machine actually do the work
# =============================================================================
command -v apache2ctl >/dev/null 2>&1 || err "apache2ctl not found. Run add_apache_webserver.sh first."
command -v systemctl  >/dev/null 2>&1 || err "systemctl not found."

[ "$NEEDS_DOTNET" -eq 1 ] && ! command -v dotnet >/dev/null 2>&1 && \
    err "app rows exist but dotnet is not on PATH. Run add_dotnet.sh first."

[ "$NEEDS_DOTNET" -eq 1 ] && ! command -v python3 >/dev/null 2>&1 && \
    err "apply_app_settings.sh needs python3. Install it: sudo apt-get install -y python3"

HAVE_CERTBOT=0
command -v certbot >/dev/null 2>&1 && HAVE_CERTBOT=1

[ "$NEEDS_CERT" -eq 1 ] && [ "$HAVE_CERTBOT" -ne 1 ] && \
    warn "Rows have a Subdomain but certbot is missing, so no certificates will be issued. Run add_certbot.sh."

if [ "$NEEDS_AUTH" -eq 1 ]; then
    [ -f "$AUTH_USER_FILE" ] || err "A row requires a login but $AUTH_USER_FILE does not exist. Create it: sudo htpasswd -c $AUTH_USER_FILE <username>"
    [ -f "$AUTH_SESSION_KEY_FILE" ] || err "A row requires a login but $AUTH_SESSION_KEY_FILE does not exist. Create it: openssl rand -base64 32 | sudo tee $AUTH_SESSION_KEY_FILE"
fi

# Environments place rows; with no rows there is nothing to place.
[ "$ROW_COUNT" -gt 0 ] || ALL_ENVS=()
for e in ${ALL_ENVS+"${ALL_ENVS[@]}"}; do
    eu="${e^^}"

    _conf_get root "APP_ROOT_${eu}" ""
    if [ -z "$root" ]; then
        err "ENVS lists '$e' but APP_ROOT_${eu} is not set"
    elif [ ! -d "$root" ]; then
        warn "APP_ROOT_${eu} does not exist yet: $root"
    fi

    # Websites resolve their document root against this, so a missing one
    # generates a vhost pointing at a path built from an empty string
    _conf_get web "WEB_ROOT_${eu}" ""
    if [ -z "$web" ]; then
        err "ENVS lists '$e' but WEB_ROOT_${eu} is not set"
    elif [ ! -d "$web" ]; then
        warn "WEB_ROOT_${eu} does not exist yet: $web"
    fi

    [ -z "$(conf_get "${eu}_BRANCH" "")" ] && warn "No ${eu}_BRANCH set, so deploys to '$e' cannot tell which branch to build"
done

BACKUP_ROOT="$(conf_get BACKUP_ROOT "")"
[ "$ROW_COUNT" -gt 0 ] && [ -z "$BACKUP_ROOT" ] && warn "No BACKUP_ROOT set, so applications have nowhere agreed to write backups"

# What the config needs, written down rather than worked out twice.
if [ -n "$FLAGS_OUT" ]; then
    {
        echo "NEEDS_AUTH=$NEEDS_AUTH"
        echo "NEEDS_CERT=$NEEDS_CERT"
        echo "NEEDS_DOTNET=$NEEDS_DOTNET"
        echo "HAVE_CERTBOT=$HAVE_CERTBOT"
        echo "ROW_COUNT=$ROW_COUNT"
    } > "$FLAGS_OUT"
fi

# =============================================================================
# What was found
# =============================================================================
if [ ${#WARNINGS[@]} -gt 0 ]; then
    for w in "${WARNINGS[@]}"; do print_info "$w"; done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

# Said out loud, because silence is not an answer. A validator that prints
# three header lines and stops reads as one that died, and the operator then
# goes looking for the failure it did not have.
print_success "Config checks out: ${ROW_COUNT} rows, nothing to fix."
exit 0
