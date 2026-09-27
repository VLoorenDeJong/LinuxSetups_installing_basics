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
# Generate every Apache vhost on this machine from
# /etc/hostings/hostings.conf.
#
#   app  reverse proxy to the app's localhost port
#   php      plain document root
#   proxy    reverse proxy a port whose unit we do not manage, e.g. Jenkins
#
# Plus two things that are not rows:
#
#   the catch-all   an unknown hostname must not be served a customer's site
#   deprecated      a dying domain gets a 301 to BASE_DOMAIN and nothing else
#
# WE WRITE THE :443 BLOCK, CERTBOT DOES NOT
#
# The previous version wrote port 80 only and let `certbot --apache` add HTTPS
# by rewriting these files. That produced the failure this machine actually had
# on 2026-08-01: two sources of truth split by protocol, HTTP served from one
# tree and HTTPS from certbot's copies in another, so editing one changed
# nothing a real visitor saw.
#
# Now add_site_certificates.sh runs `certbot certonly`, which only fetches and
# renews certificates and never opens a config file. This script owns every
# vhost, and re-running it is always safe.
#
# Chicken and egg, handled: a :443 block naming a certificate that does not
# exist fails configtest and Apache will not start. So a hostname without a
# certificate gets its :80 block only, and gains :443 on the next run after the
# certificate is issued. The order is: vhosts, certificates, vhosts again.
#
# THE CATCH-ALL IS NOT OPTIONAL
#
# The zone has a wildcard DNS record, so every possible name under BASE_DOMAIN
# reaches this machine. Apache serves the alphabetically first vhost to any
# name it does not recognise. Before the catch-all existed, that was a
# customer's backoffice, and it had been for about a year.
#
# Safe to re-run: unchanged files are left alone, and Apache is only reloaded
# after configtest passes.
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

# LIST_HOSTS=1 prints every hostname this script would publish, one per line,
# and writes nothing. It exists so maintain_services.sh can compare this list
# against the one add_site_certificates.sh would request.
#
# The comparison matters because the hostname logic is duplicated between the
# two scripts, which is deliberate: each stays runnable on its own on a machine
# that has only that file. Duplication needs a guard, and this is it. Reporting
# its own view rather than being re-derived by a third script is the point: a
# checker that reimplements the logic can drift from both.
LIST_HOSTS="${LIST_HOSTS:-0}"

# RENDER_ONLY=1 builds every vhost exactly as a real run would and compares it
# with what is on disk, then writes nothing, enables nothing and reloads
# nothing. It is how report_drift.sh answers "would this change anything"
# WITHOUT reimplementing the comparison: this file is the only place that knows
# what a vhost should contain, and a second implementation would drift from it.
#
# The gap it closes: until 2026-08-26 the drift report compared EXISTENCE only.
# Flipping a login said "nothing would change" and then Apply rewrote the vhost.
RENDER_ONLY="${RENDER_ONLY:-0}"

# What a render-only run found. One label per vhost whose content differs from
# the file on disk, which is exactly the set a real run would rewrite.
WOULD_CHANGE=()

# In list mode the hostnames are the output, so everything else moves to stderr.
# fd 3 becomes the real stdout and only hostnames are written to it.
if [ "$LIST_HOSTS" = "1" ]; then
    exec 3>&1 1>&2
fi

if [ "$LIST_HOSTS" != "1" ] && [ "$RENDER_ONLY" != "1" ] && [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

# What a disabled website serves. One folder for every disabled row, because
# the page says nothing about which site it is: naming the site would tell a
# visitor what is switched off here, and a per-row copy would drift.
OFFLINE_ROOT="/var/www/under-construction"
OFFLINE_SRC="/etc/hostings/apache/www/auth/under-construction.html"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi

if [ "$LIST_HOSTS" != "1" ] && ! command -v a2ensite >/dev/null 2>&1; then
    print_error "a2ensite not found, so Apache is not installed."
    print_action "Run add_apache_webserver.sh first, then this script."
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim into every script that reads this file
# rather than sourced, so each one stays runnable on its own on a machine that
# has only that script copied to it.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()

# Assigns into a caller variable instead of printing, because `$(conf_get ...)`
# is a fork even when the cache answers. Measured 2026-08-17: 1638 clones in one
# LIST_HOSTS run, at 4.3ms each on this machine.
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

# One clean row per line. A settings line has no pipe and would otherwise parse
# as a row whose type is the whole line.
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

# A field holding a single dash means empty. Written that way because a row of
# `| | |` cannot be counted by eye, and a miscounted row silently puts a value
# in the wrong column: that is how AuthProtected once landed in the options
# field and would have been parsed as a setting.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# The same thing, assigning rather than printing. `$(trim "$x")` still forks for
# the substitution, which is the whole cost in the row loop.
# The locals are named __t and __tv rather than anything readable, because a
# nameref pointing at a caller variable of the same name resolves to the local
# and the value is written to a scope that dies on return.
_trim() {
    local -n __t="$1"
    local __tv="$2"
    __tv="${__tv#"${__tv%%[![:space:]]*}"}"
    __tv="${__tv%"${__tv##*[![:space:]]}"}"
    [ "$__tv" = "-" ] && __tv=""
    __t="$__tv"
}

AVAILABLE_DIR="/etc/apache2/sites-available"
LE_DIR="/etc/letsencrypt/live"

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
if [ -z "$BASE_DOMAIN" ]; then
    print_error "No BASE_DOMAIN in $SITES_CONF"
    exit 1
fi

# Websites are published by deploy_static_site.sh, which runs without sudo and
# therefore needs the document root to already belong to the deploying account.
# Nothing else creates it, so the vhost generator does: it is the only per-row
# generator a website has.
APP_RUN_USER="$(conf_get APP_RUN_USER jenkins)"

# EVERY WEBSITE ROW RUNS ITS PHP AS AN ACCOUNT OF ITS OWN, item 146. In the
# shared pool one customer's PHP was www-data, which can read every other site
# and held the console's grant. Its own account cannot even enter the next
# site's folder.
PHP_FPM_VER="$(ls -d /etc/php/*/fpm 2>/dev/null | sort -V | tail -1 | cut -d/ -f4)"
POOL_DIR="/etc/php/${PHP_FPM_VER}/fpm/pool.d"
NEEDS_FPM_RELOAD=0
PRUNED_ACCOUNTS=()
declare -A SITE_ACCOUNT_ROW=()
declare -A SITE_ACCOUNT_DONE=()

# site_ plus the row, lowercased. Past 32 characters, the limit for an account
# name, it is cut and a hash of the full row added, so two long rows differ.
site_account() {
    local n
    n="site_$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')"
    if [ ${#n} -gt 32 ]; then
        n="${n:0:23}_$(printf '%s' "$1" | md5sum | cut -c1-8)"
    fi
    printf '%s' "$n"
}

# Every website row claims its name, enabled or not, so a pool is only ever
# pruned for a row that has left the config.
claim_site_account() {
    local row="$1" acct
    acct="$(site_account "$row")"
    if [ -n "${SITE_ACCOUNT_ROW[$acct]:-}" ] && [ "${SITE_ACCOUNT_ROW[$acct]}" != "$row" ]; then
        print_error "Rows '${SITE_ACCOUNT_ROW[$acct]}' and '$row' would share the account $acct."
        print_action "Rename one of them in $SITES_CONF: they differ only in case or punctuation."
        return 1
    fi
    SITE_ACCOUNT_ROW[$acct]="$row"
}

ensure_site_account() {
    local row="$1" acct content pool_file
    acct="$(site_account "$row")"
    { [ "$LIST_HOSTS" = "1" ] || [ "$RENDER_ONLY" = "1" ]; } && return 0
    [ -n "${SITE_ACCOUNT_DONE[$acct]:-}" ] && return 0
    SITE_ACCOUNT_DONE[$acct]=1

    if [ -z "$PHP_FPM_VER" ]; then
        print_error "PHP-FPM is not installed, so '$row' has no pool to run its PHP in."
        print_action "Run it first: sudo bash LinuxBasics/install_scripts/add_php.sh"
        return 1
    fi
    if ! id "$acct" >/dev/null 2>&1; then
        # A group left behind by an older prune is reused, not refused.
        local group_opt=(--user-group)
        getent group "$acct" >/dev/null && group_opt=(-g "$acct")
        useradd --system "${group_opt[@]}" --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$acct" || { print_error "Could not create the account $acct"; return 1; }
        print_status "Created the account $acct for '$row'"
    fi
    # Apache serves the static files, so it reads every site. It runs no PHP.
    if ! id -nG www-data | tr ' ' '\n' | grep -qx "$acct"; then
        usermod -aG "$acct" www-data || return 1
        NEEDS_RELOAD=1
    fi

    pool_file="${POOL_DIR}/${acct}.conf"
    content="$(cat <<EOF
; Generated by add_app_vhosts.sh from /etc/hostings/hostings.conf.
; The website row '${row}' runs its PHP here, as ${acct}, and nothing else does.
[${acct}]
user = ${acct}
group = ${acct}
listen = /run/php/${acct}.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 3
pm.process_idle_timeout = 30s
EOF
)"
    if [ ! -f "$pool_file" ] || [ "$(cat "$pool_file")" != "$content" ]; then
        printf '%s\n' "$content" > "$pool_file"
        NEEDS_FPM_RELOAD=1
        print_status "Wrote the PHP pool for '$row': runs as $acct"
    fi
}

# A pool whose row has left the config goes, and its account with it. Only on a
# run over every row: a run limited to some rows has not claimed the others.
prune_site_accounts() {
    local f acct
    [ -n "$ONLY_ROWS" ] && return 0
    { [ "$LIST_HOSTS" = "1" ] || [ "$RENDER_ONLY" = "1" ]; } && return 0
    [ -d "$POOL_DIR" ] || return 0
    for f in "$POOL_DIR"/site_*.conf; do
        [ -e "$f" ] || continue
        acct="$(basename "$f" .conf)"
        [ -n "${SITE_ACCOUNT_ROW[$acct]:-}" ] && continue
        rm -f "$f"
        NEEDS_FPM_RELOAD=1
        print_status "Removed the PHP pool $acct: its row has gone"
    done
    # Accounts go after the FPM reload, since a live worker blocks userdel. Found
    # by account, not pool, so one a previous run could not remove is retried.
    for acct in $(getent passwd | cut -d: -f1 | grep '^site_' || true); do
        [ -n "${SITE_ACCOUNT_ROW[$acct]:-}" ] && continue
        [ -e "$POOL_DIR/$acct.conf" ] && continue
        PRUNED_ACCOUNTS+=("$acct")
    done
}

remove_pruned_accounts() {
    local acct
    for acct in ${PRUNED_ACCOUNTS[@]+"${PRUNED_ACCOUNTS[@]}"}; do
        if id "$acct" >/dev/null 2>&1 && ! userdel "$acct" 2>/dev/null; then
            # A deferred reload leaves the old worker running; the next apply retries.
            if [ -n "${FPM_RELOAD_DEFER_FILE:-}" ]; then
                print_status "The account $acct is still in use, removed by the next apply."
                continue
            fi
            print_error "Could not remove the account $acct, left in place."
            FAILED+=("account $acct (not removed)")
            continue
        fi
        # userdel keeps the group while www-data is in it.
        if getent group "$acct" >/dev/null && ! groupdel "$acct"; then
            print_error "Could not remove the group $acct, left in place."
            FAILED+=("group $acct (not removed)")
            continue
        fi
        print_status "Removed the account $acct"
    done
}

# add_php.sh enables Debian's machine-wide handler, which runs PHP as www-data
# in the shared pool for any vhost that names no socket of its own. Every vhost
# here names one, so the default only catches a vhost that forgot. Item 147.
drop_shared_php_handler() {
    { [ "$LIST_HOSTS" = "1" ] || [ "$RENDER_ONLY" = "1" ]; } && return 0
    [ -n "$PHP_FPM_VER" ] || return 0
    [ -e "/etc/apache2/conf-enabled/php${PHP_FPM_VER}-fpm.conf" ] || return 0
    a2disconf -q "php${PHP_FPM_VER}-fpm" || { print_error "Could not disable php${PHP_FPM_VER}-fpm.conf"; return 1; }
    NEEDS_RELOAD=1
    print_status "Disabled php${PHP_FPM_VER}-fpm.conf: no vhost runs PHP as www-data by default"
}

# A reload with the default of 0 kills requests mid-flight, including the
# console's own while a create reloads PHP-FPM: a 503 in the browser. With a
# timeout, the old workers finish first.
ensure_graceful_fpm_reload() {
    { [ "$LIST_HOSTS" = "1" ] || [ "$RENDER_ONLY" = "1" ]; } && return 0
    [ -d "$POOL_DIR" ] || return 0
    local f="${POOL_DIR}/000-graceful-reload.conf" content
    content="$(printf '%s\n' \
        '; Generated by add_app_vhosts.sh. A reload waits for running requests.' \
        '[global]' \
        'process_control_timeout = 30s')"
    [ -f "$f" ] && [ "$(cat "$f")" = "$content" ] && return 0
    printf '%s\n' "$content" > "$f"
    NEEDS_FPM_RELOAD=1
    print_status "Wrote $f: a PHP-FPM reload lets running requests finish"
}

# Ask PHP-FPM before reloading it, so a bad pool never takes every PHP page down.
reload_php_fpm() {
    [ "$NEEDS_FPM_RELOAD" = "1" ] || return 0
    if ! "php-fpm${PHP_FPM_VER}" -t >/dev/null 2>&1; then
        print_error "PHP-FPM rejected its pools, so it was NOT reloaded:"
        "php-fpm${PHP_FPM_VER}" -t 2>&1 | tail -5
        FAILED+=("PHP-FPM pools (not reloaded)")
        return 1
    fi
    # The console's fast apply runs inside a console request, which this reload
    # would kill. It passes a file to name the reload in, and does it later.
    if [ -n "${FPM_RELOAD_DEFER_FILE:-}" ]; then
        printf 'php%s-fpm\n' "$PHP_FPM_VER" > "$FPM_RELOAD_DEFER_FILE"
        print_status "PHP-FPM reload left to the caller: the pools are written and tested."
        return 0
    fi
    systemctl reload "php${PHP_FPM_VER}-fpm" && print_success "PHP-FPM reloaded: every website runs its own pool."
}

ensure_doc_root() {
    local dir="$1" label="${2:-this site}" group="${3:-www-data}"
    if [ ! -d "$dir" ]; then
        print_status "Creating document root $dir"
        mkdir -p "$dir" || { print_error "Cannot create $dir"; return 1; }
    fi
    # An empty document root is a 403, which reads as a broken vhost rather than
    # as a site nobody has deployed to yet. Written only while the directory is
    # empty, so a deploy is never overwritten.
    if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        cat > "$dir/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>$label: nothing deployed yet</title>
<h1>$label</h1>
<p>The vhost and the certificate are in place. No content has been deployed to
this environment yet.</p>
EOF
        print_status "Wrote a placeholder into $dir"
    fi
    if ! id -u "$APP_RUN_USER" >/dev/null 2>&1; then
        print_error "APP_RUN_USER '$APP_RUN_USER' does not exist, so $dir cannot be owned."
        print_action "Run add_jenkins.sh first, or correct APP_RUN_USER in $SITES_CONF."
        return 1
    fi
    # The deploy account writes, the site's group reads, nobody else enters.
    # Setgid, so what a deploy adds joins the site's group without a chown.
    # The top folder is the gate: deploy_static_site.sh never changes its mode.
    chown -R "${APP_RUN_USER}:${group}" "$dir" || return 1
    find "$dir" -type d -exec chmod 2750 {} + || return 1
    find "$dir" -type f -exec chmod 0640 {} + || return 1
    return 0
}

AUTH_USER_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
AUTH_SESSION_KEY_FILE="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
AUTH_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"

# The account that may enter every protected site. It is named in every vhost's
# Require, which is all a master password needs to be: there is no second
# mechanism, no override flag, and nothing to switch off by accident.
AUTH_ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"

# -----------------------------------------------------------------------------
# Who may enter, and where.
#
# Until 2026-08-03 every protected vhost said `Require valid-user`, so anybody in
# the password file could reach every customer's backoffice. That was one shared
# door with several keys cut for it.
#
# Now each vhost names its own people, and the admin account is appended to all
# of them. One password file still, which is what keeps it maintainable, but the
# file no longer decides who gets in: the vhost does.
#
# A protected row with no AuthUsers resolves to the admin alone. That fails
# closed rather than open, and the pre-flight says which row it happened to.
# -----------------------------------------------------------------------------
# Who may enter, in THIS environment.
#
# A plain list is every environment, as it always was. A list holding a colon is
# read per environment, groups separated by semicolons:
#
#   carol, alice                       both, everywhere
#   live: carol; skunk: carol, bob      bob only in skunk
#
# An environment the field does not name resolves to empty, which require_users
# turns into the admin alone. Same direction as AuthProtected: unnamed fails
# closed, so a key user invited into skunk does not silently arrive in live.
users_in_env() {
    local list="$1" env="$2" grp k v
    case "$list" in
        *:*) ;;
        *) printf '%s' "$list"; return ;;
    esac

    IFS=';' read -r -a _ug <<< "$list"
    for grp in ${_ug+"${_ug[@]}"}; do
        _trim k "${grp%%:*}"
        v="${grp#*:}"
        if [ "$k" = "$env" ]; then _trim v "$v"; printf '%s' "$v"; return; fi
    done
    printf ''
}

require_users() {
    local list="$1" out="" u
    IFS=',' read -r -a _ru <<< "$list"
    for u in ${_ru+"${_ru[@]}"}; do
        _trim u "$u"
        [ -z "$u" ] && continue
        out="$out $u"
    done
    printf 'Require user%s %s' "$out" "$AUTH_ADMIN_USER"
}

# Is this row protected in this environment?
#
# AuthProtected used to be one yes or no for the whole row, with a separate
# <ENV>_FORCE_AUTH switch bolted on because a row could not say "public when
# live, locked in test", which is exactly what a public website with a test copy
# needs. Two settings for one question, and the second one invisible from the
# row you were reading.
#
# It is now per environment, written the way it reads:
#
#   live:no, test:yes
#
# A bare yes or no still works and means every environment, because most rows
# genuinely have one answer.
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

    # An environment the row says nothing about is protected. A test copy
    # published unprotected by accident is the mistake worth making impossible.
    [ "$env" = "$DEFAULT_PUBLISH" ] && return 1
    return 0
}

# Which environments get a public vhost.
#
# Defaults to every environment in ENVS. There is no dev environment, so this is
# live and test: both are on the machine and both are reached by hostname. Set
# PUBLISH_ENVS to narrow it if an environment should exist but not be published.
IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
DEFAULT_PUBLISH="$(trim "${ALL_ENVS[0]}")"
IFS=',' read -r -a PUBLISH_ENVS <<< "$(conf_get PUBLISH_ENVS "$(conf_get ENVS live)")"
for i in "${!PUBLISH_ENVS[@]}"; do
    PUBLISH_ENVS[$i]="$(trim "${PUBLISH_ENVS[$i]}")"
done

# --only-row is a flag as well as a variable, because sudo's env_reset drops
# ONLY_ROWS, and `sudo env ONLY_ROWS=x bash ...` is a different command string
# than the NOPASSWD rule for this script matches. A Jenkins job using the
# variable would die asking for a password.
while [ $# -gt 0 ]; do
    case "$1" in
        --only-row)   ONLY_ROWS="$2"; shift 2 ;;
        --only-row=*) ONLY_ROWS="${1#--only-row=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--only-row <name,name>]" >&2
            exit 1
            ;;
        *) print_error "Unknown option: $1"; exit 1 ;;
    esac
done

# ONLY_ROWS narrows vhost writing to named rows, so adding one site does not
# rewrite the other fifteen. Comma separated, matched on the second column.
#
#   sudo ./add_app_vhosts.sh --only-row mvp_progress
#
# It narrows WRITING only. The auth account pass further down still reads every
# row, because it hands the full list to add_auth_users.sh, which removes any
# account not in it: a filtered list there would delete other rows' logins.
ONLY_ROWS="$(trim "${ONLY_ROWS:-}")"
declare -A _WANTED=()
if [ -n "$ONLY_ROWS" ]; then
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

# Everything, when nothing was asked for.
row_selected() {
    [ ${#_WANTED[@]} -eq 0 ] && return 0
    [ -n "${_WANTED[$1]:-}" ]
}

print_header "Apache vhosts"
print_status "Config:      $SITES_CONF"
print_status "Base domain: $BASE_DOMAIN"
print_status "Publishing:  ${PUBLISH_ENVS[*]}"
if [ -n "$ONLY_ROWS" ]; then
    print_status "Rows:        $ONLY_ROWS (everything else left alone)"
fi

WRITTEN=()
UNCHANGED=()
SKIPPED_NO_DOMAIN=()
# A disabled row whose hostname an enabled row also serves. Reported rather than
# silently dropped: it is the off half of a pair, and saying so is how the
# operator sees that the switch actually landed.
STOOD_DOWN=()
# hostname -> the ENABLED row that serves it. Filled before the write loop by
# claim_hosts(), because a row cannot know whether it has been replaced until
# every other row has been read.
declare -A CLAIMED_BY=()
NO_CERT_YET=()
AUTH_ROWS=()
NO_AUTH_USERS=()
OPEN_NON_LIVE=()
FAILED=()
NEEDS_RELOAD=0

# Every hostname this run publishes, collected for LIST_HOSTS mode
PUBLISHED_HOSTS=()
INCLUDE_ASKED=0

# -----------------------------------------------------------------------------
# Resolve a row's Subdomain field into a hostname for one environment.
#
#   demo        demo.BASE_DOMAIN, prefixed per environment
#   @           BASE_DOMAIN itself
#   =full.tld   a complete domain, BASE_DOMAIN is not appended
#   empty       no hostname, so nothing is published
# -----------------------------------------------------------------------------
# Assigns into a caller variable and returns 1 when there is no hostname, so the
# row loop does not fork once per row per environment to read one string.
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

cert_exists() {
    [ -f "${LE_DIR}/$1/fullchain.pem" ] && [ -f "${LE_DIR}/$1/privkey.pem" ]
}

# Write a vhost file, enable it, and record what happened. Unchanged files are
# left alone so a re-run does not restart anything needlessly.
install_vhost() {
    local file="$1" label="$2" content="$3"

    # LIST_HOSTS reports only, so nothing is written or enabled
    [ "$LIST_HOSTS" = "1" ] && return 0

    # RENDER_ONLY compares and reports, and stops there. The comparison is the
    # same one a real run makes three lines down, which is the whole point:
    # there is one answer to "would this change", not two.
    if [ "$RENDER_ONLY" = "1" ]; then
        if [ ! -f "$file" ]; then
            WOULD_CHANGE+=("$label (new)")
        elif [ "$(cat "$file")" != "$content" ]; then
            WOULD_CHANGE+=("$label")
        fi
        return 0
    fi


    if [ -f "$file" ] && [ "$(cat "$file")" = "$content" ]; then
        UNCHANGED+=("$label")
    else
        printf '%s\n' "$content" > "$file"
        chmod 644 "$file"
        WRITTEN+=("$label")
        NEEDS_RELOAD=1
    fi

    # An existing link is already enabled; a2ensite costs a Perl start per vhost.
    if [ ! -e "/etc/apache2/sites-enabled/$(basename "$file")" ] &&
       ! a2ensite "$(basename "$file")" >/dev/null 2>&1; then
        print_error "Could not enable $(basename "$file")"
        FAILED+=("$label (a2ensite failed)")
        return 1
    fi
    return 0
}

# The :443 wrapper, shared by every vhost that has a certificate.
# The TLS settings every :443 block includes.
#
# NOT certbot's /etc/letsencrypt/options-ssl-apache.conf. That file is written by
# certbot's APACHE PLUGIN, which this setup never runs: certbot here is certonly
# and touches no Apache config at all. So the include pointed at a file nothing
# would ever create, and Apache refused to start once a vhost gained a :443
# block.
#
# Owning it also means the settings are visible here rather than in a file
# somebody else's upgrade can change.
SSL_OPTIONS_FILE="/etc/apache2/conf-available/ssl-options.conf"

write_ssl_options() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
# Generated by add_app_vhosts.sh. Do not edit by hand.
#
# Included by every :443 vhost. Mozilla's intermediate recommendation: TLS 1.2
# and 1.3 only, and no cipher suite without forward secrecy.
SSLEngine on
SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1
SSLCipherSuite          ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384
SSLHonorCipherOrder     off
SSLSessionTickets       off
EOF
    if [ ! -f "$SSL_OPTIONS_FILE" ] || ! cmp -s "$tmp" "$SSL_OPTIONS_FILE"; then
        install -m 0644 -o root -g root "$tmp" "$SSL_OPTIONS_FILE"
        print_success "Wrote $SSL_OPTIONS_FILE"
        NEEDS_RELOAD=1
    fi
    rm -f "$tmp"
}

ssl_block() {
    local host="$1"
    cat <<EOF
    SSLCertificateFile    ${LE_DIR}/${host}/fullchain.pem
    SSLCertificateKeyFile ${LE_DIR}/${host}/privkey.pem
    Include ${SSL_OPTIONS_FILE}
EOF
}

# -----------------------------------------------------------------------------
# Authentication for rows with AuthProtected = yes.
#
# The application has no login of its own, so without this anyone who finds the
# URL can read, edit and delete a customer's data. That was the live state of
# this machine until 2026-08-01.
#
# The method is forced by the transport rather than chosen:
#
#   :443  a form login, so password managers can autofill it
#   :80   basic auth, because the session cookie below is set `secure` and a
#         browser will not send it back over HTTP. A form login there redirects
#         forever.
#
# Emitted inline per vhost rather than as a shared Include. The generator owns
# the repetition, and each vhost stays a complete, readable description of what
# it does.
# -----------------------------------------------------------------------------
auth_form_block() {
    local proxied="$1" users="$2" login_page="${3:-login.html}" transport="${4:-tls}"
    local exclusions="" require_line cookie
    require_line="$(require_users "$users")"

    # A `secure` cookie is never sent back over plain HTTP, so a plain-HTTP door
    # needs its own name as well: cookies ignore the port, and reusing `session`
    # would collide with the one :443 sets on the same hostname.
    if [ "$transport" = "plain" ]; then
        cookie="SessionCookieName session_http path=/;httponly"
    else
        cookie="SessionCookieName session path=/;httponly;secure"
    fi

    # Only a proxied vhost needs these. A website is served from disk, so there
    # is no ProxyPass for the login page to be swallowed by, and emitting them
    # anyway is a no-op that reads as though it matters.
    if [ "$proxied" = "yes" ]; then
        exclusions="$(cat <<EOF
    # These must appear before the ProxyPass below, or the login page is proxied
    # to the application instead of being served from disk.
    ProxyPass /${login_page}   !
    ProxyPass /do-login     !
    ProxyPass /logout       !
    ProxyPass /auth-assets  !
EOF
)"
    fi

    cat <<EOF

    # --- Login -------------------------------------------------------------
    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> must come FIRST and the exceptions
    # after it. Reversed, the login page itself requires a login and loops.
${exclusions}

    Alias /${login_page} ${AUTH_WEB_ROOT}/${login_page}
    Alias /auth-assets ${AUTH_WEB_ROOT}
    <Directory ${AUTH_WEB_ROOT}>
        Require all granted
    </Directory>

    <Location />
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_USER_FILE}
        AuthFormLoginRequiredLocation /${login_page}
        # No KeptBodySize: see add_hosting_manager.sh, it segfaults Apache on a slow POST.
        Session On
        ${cookie}
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY_FILE}
        ${require_line}
    </Location>

    <Location /${login_page}>
        AuthType None
        Require all granted
    </Location>

    <Location /auth-assets>
        AuthType None
        Require all granted
    </Location>

    <Location /do-login>
        SetHandler form-login-handler
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_USER_FILE}
        AuthFormLoginRequiredLocation /${login_page}
        AuthFormLoginSuccessLocation /
        Session On
        ${cookie}
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY_FILE}
        Require all granted
    </Location>

    <Location /logout>
        SetHandler form-logout-handler
        AuthType None
        AuthFormLogoutLocation /${login_page}
        Session On
        ${cookie}
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY_FILE}
        Require all granted
    </Location>
EOF
}

# =============================================================================
# The catch-all.
#
# 000- so it sorts first, which is what makes it Apache's default server for
# any hostname with no vhost of its own. Redirect rather than proxy: the visitor
# ends up on a hostname the certificate actually covers.
#
# Browsers will still refuse an unknown name under a HSTS-preloaded TLD such as
# .dev, because no certificate covers a name nobody issued one for. That is a
# hard failure rather than a wrong page, which is the point.
# =============================================================================
build_catchall() {
    local file="$AVAILABLE_DIR/000-catchall.conf"
    local ssl=""

    if cert_exists "$BASE_DOMAIN"; then
        ssl="$(cat <<EOF

<VirtualHost *:443>
    ServerName catchall.invalid
$(ssl_block "$BASE_DOMAIN")
    RewriteEngine On
    RewriteRule ^ https://${BASE_DOMAIN}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF
)"
    else
        NO_CERT_YET+=("catch-all (no certificate for $BASE_DOMAIN yet)")
    fi

    local content
    content="$(cat <<EOF
# Generated by add_app_vhosts.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
#
# Apache serves the alphabetically first vhost to any hostname it does not
# recognise. The 000- prefix makes that this file rather than whichever
# customer's site happens to sort first.
#
# This is load bearing because the DNS zone has a wildcard record: every
# possible name under ${BASE_DOMAIN} reaches this machine, including names
# nobody configured and anything an internet scanner probes.
<VirtualHost *:80>
    ServerName catchall-http.invalid
    RewriteEngine On
    RewriteRule ^ https://${BASE_DOMAIN}%{REQUEST_URI} [R=301,L]
</VirtualHost>
${ssl}
EOF
)"

    install_vhost "$file" "000-catchall" "$content" || true
}

# =============================================================================
# Deprecated domains: a 301 to BASE_DOMAIN and nothing else, so a dying domain
# is one word to maintain and one line to delete.
# =============================================================================
build_deprecated() {
    local domains dom file content ssl
    domains="$(conf_get DEPRECATED_DOMAINS "")"
    [ -z "$domains" ] && return 0

    IFS=',' read -r -a dom_list <<< "$domains"
    for dom in "${dom_list[@]}"; do
        dom="$(trim "$dom")"
        [ -z "$dom" ] && continue

        # www is on the ServerAlias and on the certificate, so it belongs in the
        # published list too. Leaving it out made add_dns_records.sh report the
        # www record as an orphan and advise deleting it, which would have
        # broken the redirect it exists for.
        PUBLISHED_HOSTS+=("$dom" "www.$dom")
        ssl=""
        if cert_exists "$dom"; then
            ssl="$(cat <<EOF

<VirtualHost *:443>
    ServerName ${dom}
    ServerAlias www.${dom}
$(ssl_block "$dom")
    RewriteEngine On
    RewriteRule ^ https://${BASE_DOMAIN}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF
)"
        else
            NO_CERT_YET+=("${dom} (deprecated, no certificate)")
        fi

        file="$AVAILABLE_DIR/010-deprecated-${dom}.conf"
        content="$(cat <<EOF
# Generated by add_app_vhosts.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
#
# ${dom} is in DEPRECATED_DOMAINS. It answers, and redirects, and does nothing
# else. It is kept rather than deleted on purpose: a name that stops resolving
# to anything would fall through to whichever vhost sorts first.
<VirtualHost *:80>
    ServerName ${dom}
    ServerAlias www.${dom}
    RewriteEngine On
    RewriteRule ^ https://${BASE_DOMAIN}%{REQUEST_URI} [R=301,L]
</VirtualHost>
${ssl}
EOF
)"
        install_vhost "$file" "deprecated:${dom}" "$content" || true
    done
}

# =============================================================================
# webmail.<domain>, one per mail domain
# =============================================================================
# The owner's call, 2026-09-10: every mail domain gets its own name rather than one
# shared webmail on the base domain. Roundcube authenticates on the full address
# either way, so the difference is whose name is in the address bar.
#
# Built HERE rather than as a PANEL row or an installer of its own, because this
# script is the single source of hostnames: add_dns_records.sh and
# add_site_certificates.sh both read LIST_HOSTS, so a name added here gets its
# record and its certificate with no other script being told about it.
#
# The mail domains are the mailbox rows' domains, which is the same set
# add_dovecot.sh and add_rspamd.sh serve. A domain with no mailbox gets no
# webmail: there would be nobody to sign in.
build_webmail() {
    local root dom local_part domain file content ssl
    root="$(conf_get WEBMAIL_ROOT /var/lib/roundcube/public_html)"
    if [ ! -d "$root" ]; then
        [ "$LIST_HOSTS" = "1" ] || print_status "No Roundcube at $root, so no webmail name is published."
        return 0
    fi

    local -A seen=()
    while IFS='|' read -r type local_part _p _path domain _rest; do
        [ "$(trim "$type")" = "mailbox" ] || continue
        local_part="$(trim "$local_part")"; domain="$(trim "$domain")"
        [ -z "$local_part" ] && continue
        [ -z "$domain" ] && domain="$BASE_DOMAIN"
        [ -z "$domain" ] && continue
        [ -n "${seen[$domain]:-}" ] && continue
        seen["$domain"]=1

        dom="webmail.${domain}"
        PUBLISHED_HOSTS+=("$dom")

        ssl=""
        if cert_exists "$dom"; then
            ssl="$(cat <<EOF

<VirtualHost *:443>
    ServerName ${dom}
    DocumentRoot ${root}
$(ssl_block "$dom")
    <Directory ${root}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        # Roundcube's own pool, written by add_roundcube.sh. Item 146.
        <FilesMatch "\.php\$">
            SetHandler "proxy:unix:/run/php/roundcube.sock|fcgi://roundcube"
        </FilesMatch>
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/webmail-${domain}-error.log
    CustomLog \${APACHE_LOG_DIR}/webmail-${domain}-access.log combined
</VirtualHost>
EOF
)"
        else
            NO_CERT_YET+=("${dom} (webmail, no certificate)")
        fi

        # Port 80 redirects and serves nothing. A mail login is a password over
        # the wire: there is no version of this that is acceptable in clear text,
        # so the plain vhost exists only to send a visitor to the secure one and
        # to answer an HTTP-01 challenge if one is ever used here.
        file="$AVAILABLE_DIR/020-webmail-${domain}.conf"
        content="$(cat <<EOF
# Generated by add_app_vhosts.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
#
# Webmail for ${domain}. One name per mail domain, all serving the same
# Roundcube: it signs in on the full address, so the name is whose it looks like.
<VirtualHost *:80>
    ServerName ${dom}
    RewriteEngine On
    RewriteRule ^ https://${dom}%{REQUEST_URI} [R=301,L]
</VirtualHost>
${ssl}
EOF
)"
        install_vhost "$file" "webmail:${domain}" "$content" || true
    done < <(grep -E '^[[:space:]]*mailbox[[:space:]]*\|' "$SITES_CONF" 2>/dev/null || true)
}

# =============================================================================
# One vhost per row, per published environment
# =============================================================================
# Written every run, so an edit to the page reaches the machine with the rest
# of the vhosts and needs no installer of its own.
install_offline_page() {
    # Neither of these modes may write, and RENDER_ONLY is not even root.
    if [ "$LIST_HOSTS" = "1" ] || [ "$RENDER_ONLY" = "1" ]; then return 0; fi
    if [ ! -f "$OFFLINE_SRC" ]; then
        print_warning "No under-construction page at $OFFLINE_SRC, so a disabled website would serve Apache's default."
        return 0
    fi
    install -d -m 0755 -o root -g root "$OFFLINE_ROOT"
    install -m 0644 -o root -g root "$OFFLINE_SRC" "$OFFLINE_ROOT/index.html"
}

# Which ENABLED row serves each hostname.
#
# Two rows for one customer is the intended shape, 2026-09-10: a www_ row
# serving files and an app_ row running a service, switched by ticking one and
# unticking the other. The off half must publish NOTHING, or both would write a
# ServerName for the same hostname and Apache would answer with whichever it
# read first.
#
# Every row is read here, not only the selected ones: ONLY_ROWS may name the
# disabled half alone, and it still has to know who replaced it.
claim_hosts() {
    local type name port path sub datasource options authprotected
    local siterepo sitebranch rowenvs authusers repomode runtime enabled
    local env prefix host

    while IFS='|' read -r type name port path sub datasource options authprotected siterepo sitebranch rowenvs authusers repomode runtime enabled owner; do
        _trim type "$type"; _trim name "$name"; _trim sub "$sub"
        _trim enabled "$enabled"; enabled="${enabled,,}"
        [ -z "$enabled" ] || [ "$enabled" = "-" ] && enabled="yes"
        [ "$enabled" = "no" ] && continue
        [ -z "$type" ] || [ "$type" = "mailbox" ] && continue
        [ -z "$name" ] || [ -z "$sub" ] && continue

        for env in "${PUBLISH_ENVS[@]}"; do
            row_in_env "$rowenvs" "$env" || continue
            _conf_get prefix "${env^^}_HOST_PREFIX" ""
            _resolve_host host "$sub" "$prefix" || continue
            [ -z "${CLAIMED_BY[$host]:-}" ] && CLAIMED_BY["$host"]="$name"
        done
    done < <(conf_rows)
}

build_rows() {
    # Every one of these is declared, and that is now a safety property rather
    # than tidiness: a nameref resolves through the whole call stack, so a helper
    # writing into `env` would reach this loop's variable if it were global.
    local type name port path sub datasource options authprotected
    local siterepo sitebranch rowenvs authusers repomode runtime enabled
    local env env_upper prefix offset env_port host file body content ssl web_root doc_root site_acct
    local offline_fallback
    local auth_443 auth_80 login_page users_here

    # AuthUsers is appended as the LAST field rather than slotted in next to
    # AuthProtected, so that every existing column keeps its position. The
    # Jenkins deploy pipeline reads the repository and branch by number.
    while IFS='|' read -r type name port path sub datasource options authprotected siterepo sitebranch rowenvs authusers repomode runtime enabled owner; do
        _trim type "$type"
        _trim name "$name"
        row_selected "$name" || continue
        _trim port "$port"
        _trim path "$path"
        _trim sub "$sub"
        _trim authusers "$authusers"
        _trim authprotected "$authprotected"
        authprotected="${authprotected,,}"
        # A row written before the Enabled field existed has no fifteenth
        # column, and every row on every machine was enabled until then.
        _trim enabled "$enabled"
        enabled="${enabled,,}"
        if [ -z "$enabled" ] || [ "$enabled" = "-" ]; then enabled="yes"; fi

        [ -z "$type" ] && continue

        # Mail rows have no web presence. add_mail_store.sh and add_dovecot.sh
        # own them, and they read this same file.
        [ "$type" = "mailbox" ] && continue

        # mod_include is what processes the .shtml error pages. Enabling it here
        # rather than assuming: it is not on by default, and without it Apache
        # serves those files raw, echo directives and all.
        case "$type" in
            website|php|docroot)
                # Asked once, not once per row: apache2ctl -M parses the whole
                # Apache config, which is the most expensive thing in this loop.
                # Never asked at all in list mode, which writes nothing.
                if [ "$LIST_HOSTS" != "1" ] && [ "$RENDER_ONLY" != "1" ] && [ "$INCLUDE_ASKED" -eq 0 ]; then
                    INCLUDE_ASKED=1
                    if ! apache2ctl -M 2>/dev/null | grep -q include_module; then
                        a2enmod include >/dev/null 2>&1 && print_success "Enabled mod_include"
                        NEEDS_RELOAD=1
                    fi
                fi
                ;;
        esac


        if [ -z "$name" ]; then
            print_error "Row with subdomain '$sub' has no ApplicationName, cannot name its vhost."
            FAILED+=("${sub:-<unnamed row>} (no name)")
            continue
        fi

        if [ -z "$sub" ]; then
            SKIPPED_NO_DOMAIN+=("$name")
            continue
        fi

        for env in "${PUBLISH_ENVS[@]}"; do
            row_in_env "$rowenvs" "$env" || continue
            env_upper="${env^^}"
            _conf_get prefix "${env_upper}_HOST_PREFIX" ""

            if ! _resolve_host host "$sub" "$prefix"; then
                continue
            fi

            # The off half of a pair publishes NOTHING: no vhost, no hostname,
            # so no certificate either. A disabled row on a hostname nobody else
            # serves still gets the under-construction page below, which is the
            # ordinary meaning of switching a site off.
            if [ "$enabled" = "no" ] && [ -n "${CLAIMED_BY[$host]:-}" ] \
               && [ "${CLAIMED_BY[$host]}" != "$name" ]; then
                STOOD_DOWN+=("$name/$env -> ${CLAIMED_BY[$host]}")
                continue
            fi

            PUBLISHED_HOSTS+=("$host")

            # www belongs to a bare domain and nowhere else.
            # www.test-portfolio.example.com is meaningless, so only a
            # hostname that IS a registered domain gets the alias.
            #
            # The domain without www is the real one. www answers, and sends a
            # 301 to it, so a visitor never sees two addresses for one site and
            # a search engine never indexes both.
            local www_alias="" www_redirect=""
            case "$host" in
                *.*.*) ;;
                *.*)
                    www_alias="    ServerAlias www.${host}"
                    www_redirect="    # www is not the real name. Sent to the one that is.
    RewriteEngine On
    RewriteCond %{HTTP_HOST} ^www\\. [NC]
    RewriteRule ^ https://${host}%{REQUEST_URI} [R=301,L]"
                    PUBLISHED_HOSTS+=("www.${host}")
                    ;;
            esac

            # The hostname is the whole answer in list mode. Everything below
            # builds vhost text for install_vhost to discard.
            [ "$LIST_HOSTS" = "1" ] && continue

            # Auth is decided per environment, by the row itself.
            #
            # The row says `live:no, test:yes` where the answer differs, which is
            # what a public website with a locked test copy needs. A bare yes or
            # no means every environment. An environment the row does not mention
            # is protected, so a test copy cannot be published open by accident.
            auth_443=""
            auth_80=""
            if auth_in_env "$authprotected" "$env"; then
                # A non-live environment gets its own login page. The page is the
                # first thing anyone sees, which makes it the right place to say
                # in plain words that nothing done here is real. A colour or a
                # banner further in is seen after the damage.
                login_page="login.html"
                [ "$env" != "$DEFAULT_PUBLISH" ] && login_page="login-${env}.html"

                users_here="$(users_in_env "$authusers" "$env")"

                case "$type" in
                    app|proxy) auth_443="$(auth_form_block yes "$users_here" "$login_page")" ;;
                    *)             auth_443="$(auth_form_block no  "$users_here" "$login_page")" ;;
                esac
                case "$type" in
                    app|proxy) auth_80="$(auth_form_block yes "$users_here" "$login_page" plain)" ;;
                    *)             auth_80="$(auth_form_block no  "$users_here" "$login_page" plain)" ;;
                esac
                AUTH_ROWS+=("$name/$env")

                if [ -z "$authusers" ]; then
                    # Fails closed: only the admin can enter. Said out loud
                    # because a customer locked out of their own site is a
                    # support call, and this is cheaper than that call.
                    NO_AUTH_USERS+=("$name/$env")
                fi
            elif [ "$env" != "$DEFAULT_PUBLISH" ]; then
                # A bare `no` is taken at its word, because that is what it says.
                # But it means a copy of a real site is published open, on a
                # domain where names are easy to guess, and that is worth saying
                # out loud rather than inferring silently in either direction.
                OPEN_NON_LIVE+=("$name/$env")
            fi
            _conf_get offset "${env_upper}_PORT_OFFSET" 0

            # A proxy row is something running its own unit on its own port, so
            # there is exactly one of it however many environments exist
            case "$type" in
                proxy) [ "$env" != "$DEFAULT_PUBLISH" ] && continue ;;
            esac

            case "$type" in
                app|proxy)
                    if [ -z "$port" ]; then
                        print_error "$type row '$name' has a subdomain but no port."
                        FAILED+=("$name (no port)")
                        continue
                    fi
                    # A proxy row's port is not ours to shift: the service owns
                    # its own unit and listens where it listens
                    if [ "$type" = "proxy" ]; then
                        env_port="$port"
                    else
                        env_port=$((port + offset))
                    fi
                    body="$(cat <<EOF
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${env_port}/
    ProxyPassReverse / http://127.0.0.1:${env_port}/

    # Kestrel needs to know the request arrived over HTTPS, otherwise every URL
    # the app generates comes back as http and mixed content breaks it
    RequestHeader set X-Forwarded-Proto expr=%{REQUEST_SCHEME}
    RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"

    # WebSockets do not survive a plain HTTP proxy: SignalR and Blazor Server
    # fall back to long polling or fail outright without this
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://127.0.0.1:${env_port}/\$1 [P,L]
EOF
)"
                    ;;
                website|php|docroot)
                    if [ -z "$path" ]; then
                        print_error "$type row '$name' has a subdomain but no document root."
                        FAILED+=("$name (no path)")
                        continue
                    fi
                    # Relative to this environment's web root, so one row serves
                    # every environment from its own directory. Into a separate
                    # variable, never back into $path: that is the row's value
                    # and the next environment in this loop still needs it.
                    _conf_get web_root "WEB_ROOT_${env_upper}" ""
                    if [ -z "$web_root" ]; then
                        print_error "ENVS lists '$env' but WEB_ROOT_${env_upper} is not set, and '$name' is a website."
                        FAILED+=("$name/$env (no WEB_ROOT_${env_upper})")
                        continue
                    fi
                    # A disabled website keeps its names, its ports and its
                    # certificate, and serves one page saying it is off. Only
                    # the document root moves, so enabling it again is this
                    # script run once more.
                    #
                    # Decided BEFORE ensure_doc_root, not after: a site that is
                    # switched off does not need its real root to exist, and
                    # requiring it meant a row could not be disabled while its
                    # root was still missing, which is exactly the state you
                    # most want to switch off.
                    offline_fallback=""
                    site_acct="$(site_account "$name")"
                    claim_site_account "$name" || { FAILED+=("$name (account name)"); continue; }
                    if [ "$enabled" != "no" ]; then
                        doc_root="${web_root%/}/${path#/}"
                        ensure_site_account "$name" || { FAILED+=("$name (PHP pool)"); continue; }
                        ensure_doc_root "$doc_root" "$name/$env" "$site_acct" || { FAILED+=("$name/$env (document root)"); continue; }
                    fi
                    if [ "$enabled" = "no" ]; then
                        doc_root="$OFFLINE_ROOT"
                        # Every path answers with the page, so a visitor with a
                        # deep link is told the site is off rather than given a
                        # 404 that reads as broken.
                        offline_fallback="
    FallbackResource /index.html"
                    fi
                    # Custom error pages, each guarded so a site without them
                    # keeps Apache's built-in ones. Without the guard, an
                    # ErrorDocument pointing at a missing file produces
                    # "Additionally, a 404 was encountered while trying to use
                    # an ErrorDocument", which is worse than the default page.
                    #
                    # <IfFile> needs Apache 2.4.34 or later. Ubuntu 24.04 ships
                    # 2.4.58.
                    #
                    # html is emitted before shtml so that if a site somehow has
                    # both, the later directive wins and the shtml one is used.
                    error_docs=""
                    for code in 400 401 403 404 500; do
                        for ext in html shtml; do
                            error_docs="${error_docs}
    <IfFile \"${doc_root%/}/${code}.${ext}\">
        ErrorDocument ${code} /${code}.${ext}
    </IfFile>"
                        done
                    done

                    body="$(cat <<EOF
    DocumentRoot ${doc_root}${offline_fallback}

    <Directory ${doc_root}>
        # +IncludesNOEXEC rather than +Includes: these pages use <!--#echo -->
        # and nothing more. Plain Includes would also permit <!--#exec cmd -->,
        # which turns write access to any .shtml file into command execution,
        # and this content is deployed from a git repository.
        Options -Indexes +FollowSymLinks +IncludesNOEXEC
        AddOutputFilter INCLUDES .shtml
        # A .htaccess comes from the customer's repository, so it may not name
        # a handler, a proxy or a rewrite: any of those can hand this site's
        # files to another account's PHP pool. FallbackResource covers routing.
        AllowOverride None
        AllowOverrideList DirectoryIndex FallbackResource ErrorDocument Redirect RedirectMatch RedirectPermanent RedirectTemp Header ExpiresActive ExpiresByType ExpiresDefault AddType AddCharset AddDefaultCharset
        Require all granted
        <FilesMatch "\.php\$">
            SetHandler "proxy:unix:/run/php/${site_acct}.sock|fcgi://${site_acct}"
        </FilesMatch>
    </Directory>
${error_docs}

    # A website is deployed from a git repository. deploy_static_site.sh
    # excludes .git from the copy, so this should never match anything. It is
    # here because a repository under the web root means the full source and
    # history are downloadable, scanners probe /.git/config as a matter of
    # routine, and one belt costs nothing next to one pair of braces.
    RedirectMatch 404 /\\.git
EOF
)"
                    ;;
                *)
                    print_error "Unknown ServiceType '$type' on row '$name'. Expected app, website or proxy."
                    FAILED+=("$name (unknown type: $type)")
                    continue
                    ;;
            esac

            ssl=""
            if cert_exists "$host"; then
                ssl="$(cat <<EOF

<VirtualHost *:443>
    ServerName ${host}
${www_alias}
$(ssl_block "$host")
${www_redirect}
${auth_443}

${body}

    ErrorLog \${APACHE_LOG_DIR}/${name}-${env}-error.log
    CustomLog \${APACHE_LOG_DIR}/${name}-${env}-access.log combined
</VirtualHost>
EOF
)"
            else
                NO_CERT_YET+=("${host}")
            fi

            # Until a certificate exists, :80 has to serve the site rather than
            # redirect to an HTTPS vhost that is not there yet. Once it exists,
            # :80 becomes a redirect and nothing is served in the clear.
            local http_body
            if [ -n "$ssl" ]; then
                http_body="$(cat <<EOF
    # Everything over HTTPS. The ACME challenge path is the one exception, so
    # renewals keep working without opening the site up.
    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\.well-known/acme-challenge/
    RewriteRule ^ https://${host}%{REQUEST_URI} [R=301,L]

    DocumentRoot /var/www/certbot
EOF
)"
            else
                # No certificate yet, so :80 is serving the site itself and
                # needs the lock too
                http_body="${auth_80}

${body}"
            fi

            file="$AVAILABLE_DIR/${name}-${env}.conf"
            content="$(cat <<EOF
# Generated by add_app_vhosts.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit the config instead.
#
# ${name}, environment ${env}, served at ${host}
#
# Both blocks are written here. certbot runs with certonly and never opens a
# vhost file, so this script is the only thing that writes Apache config and
# re-running it is always safe.
<VirtualHost *:80>
    ServerName ${host}
${www_alias}

${http_body}

    ErrorLog \${APACHE_LOG_DIR}/${name}-${env}-error.log
    CustomLog \${APACHE_LOG_DIR}/${name}-${env}-access.log combined
</VirtualHost>
${ssl}
EOF
)"
            install_vhost "$file" "${name}/${env}" "$content" || true
        done
    done < <(conf_rows)
}

# The webroot certbot writes its challenge files into. Created here because the
# :80 blocks above point at it, and a DocumentRoot that does not exist makes
# Apache log an error on every request.
if [ "$LIST_HOSTS" != "1" ]; then
    mkdir -p /var/www/certbot
    chmod 755 /var/www/certbot
    # Before any vhost is written, since every :443 block includes it.
    write_ssl_options
fi

build_catchall
build_deprecated
build_webmail
install_offline_page
claim_hosts
build_rows
prune_site_accounts
ensure_graceful_fpm_reload
drop_shared_php_handler || FAILED+=("php${PHP_FPM_VER}-fpm.conf (still enabled)")
# Before Apache is reloaded, so every socket a vhost names already exists.
reload_php_fpm || true
remove_pruned_accounts

# LIST_HOSTS: report what would be published, then stop. Nothing was written,
# because install_vhost returns early in this mode.
if [ "$LIST_HOSTS" = "1" ]; then
    printf '%s\n' "${PUBLISHED_HOSTS[@]}" | sort -u >&3
    exit 0
fi

# -----------------------------------------------------------------------------
# Everything the protected rows depend on. Done after the rows so we only touch
# any of it when something actually asked for a login.
# -----------------------------------------------------------------------------
if [ ${#AUTH_ROWS[@]} -gt 0 ]; then
    print_status "Login required by: ${AUTH_ROWS[*]}"

    # Every non-live environment references a login page of its own. A vhost
    # pointing at a page that does not exist gives a 404 where the login should
    # be, which reads as a broken site rather than a missing file.
    for env in "${PUBLISH_ENVS[@]}"; do
        [ "$env" = "$DEFAULT_PUBLISH" ] && continue
        if [ ! -f "/etc/hostings/apache/www/auth/login-${env}.html" ] &&
           [ ! -f "$REPO_ROOT/install_scripts/assets/auth/login-${env}.html" ]; then
            print_error "No login page for the '$env' environment."
            print_action "Every environment other than '$DEFAULT_PUBLISH' needs its own, so it can"
            print_action "say plainly that it is not the real site. Create it by copying:"
            print_action "  cp /etc/hostings/apache/www/auth/login-test.html \\"
            print_action "     /etc/hostings/apache/www/auth/login-${env}.html"
            FAILED+=("missing login-${env}.html")
        fi
    done

    # mod_auth_form needs all five. Missing any one is a configtest failure
    # rather than a silent hole, but enabling them here means the operator never
    # meets that error.
    # Asked once: each apache2ctl -M parses the whole Apache config. Render mode
    # enables nothing, so it does not ask.
    loaded_mods=""
    [ "$RENDER_ONLY" = "1" ] || loaded_mods="$(apache2ctl -M 2>/dev/null || true)"
    for mod in auth_form session session_cookie session_crypto request; do
        [ "$RENDER_ONLY" = "1" ] && break
        if ! grep -q "${mod}_module" <<< "$loaded_mods"; then
            a2enmod "$mod" >/dev/null 2>&1 && print_success "Enabled mod_${mod}"
            NEEDS_RELOAD=1
        fi
    done

    # The login pages are versioned and copied here, never edited on the machine.
    # The path mirrors /var/www/, so /etc/hostings/apache/www/auth/ lands at
    # /var/www/auth/.
    #
    # Two sources, shared first and local on top. That is the opposite of the
    # rule for scripts, and deliberately so: a script is behaviour and two
    # copies of it drift in silence, but a login page is a face. LinuxBasics
    # carries a plain one that works anywhere, and a machine puts its own name
    # and logo over it. Laying the local copy second means a machine only has to
    # carry the files it actually changed.
    BASICS_AUTH="$REPO_ROOT/install_scripts/assets/auth"
    AUTH_SRC="/etc/hostings/apache/www/auth"

    if [ -d "$BASICS_AUTH" ] || [ -d "$AUTH_SRC" ]; then
        mkdir -p "$AUTH_WEB_ROOT"
        chmod 755 "$AUTH_WEB_ROOT"

        if [ -d "$BASICS_AUTH" ]; then
            cp -r "$BASICS_AUTH/." "$AUTH_WEB_ROOT/"
            print_success "Generic login pages deployed from LinuxBasics"
        fi
        if [ -d "$AUTH_SRC" ]; then
            cp -r "$AUTH_SRC/." "$AUTH_WEB_ROOT/"
            print_success "Local login pages laid over them from /etc/hostings/"
        fi

        find "$AUTH_WEB_ROOT" -type f -exec chmod 644 {} +
    else
        print_info "No login pages found in LinuxBasics or /etc/hostings/, so none were deployed."
        print_info "Sites requiring a login will redirect to a page that does not exist."
    fi

    # These two hold secrets, so they are never generated from the repo. Say
    # exactly what to run rather than leaving a configtest failure to decode.
    if [ ! -f "$AUTH_USER_FILE" ]; then
        # Not an error any more: the account loop below creates it with the
        # first person added, using -c exactly once. Reporting a failure here
        # and then fixing it four lines later would just be noise.
        print_status "No user file at $AUTH_USER_FILE yet. It is created below."
    fi

    # Generated rather than demanded. It is 32 random bytes with no meaning to
    # anyone: there is nothing to decide, nothing to remember and nothing to
    # type, so stopping the install to make somebody paste a command was asking
    # them to be a random number generator.
    #
    # Not in the repo and never printed: whoever holds it can forge a session
    # cookie for every protected site at once.
    if [ ! -f "$AUTH_SESSION_KEY_FILE" ]; then
        if openssl rand -base64 32 > "$AUTH_SESSION_KEY_FILE" 2>/dev/null; then
            chmod 600 "$AUTH_SESSION_KEY_FILE"
            chown root:root "$AUTH_SESSION_KEY_FILE" 2>/dev/null || true
            print_success "Generated a session key at $AUTH_SESSION_KEY_FILE"
        else
            print_error "Could not generate $AUTH_SESSION_KEY_FILE"
            print_action "Create it by hand:  openssl rand -base64 32 | sudo tee $AUTH_SESSION_KEY_FILE"
            print_action "Then:               sudo chmod 600 $AUTH_SESSION_KEY_FILE"
            FAILED+=("missing $AUTH_SESSION_KEY_FILE")
        fi
    fi

    # Which accounts this config expects. Only the admin is ASKED for: every
    # other login is made in the console's Users tab and comes back from the
    # secret store (login-store-decisions.md, decision 1). A row naming an
    # account that exists nowhere is reported, because Apache refuses it
    # silently: an absent account and a wrong password look the same.
    EXPECTED_ACCOUNTS=("$AUTH_ADMIN_USER")
    ROW_ACCOUNTS=()
    while IFS='|' read -r _t _n _p _pa _s _d _o _ap _r _b _e au _rm _rt _enabled _owner; do
        au="$(trim "$au")"
        [ -z "$au" ] && continue
        # Per environment when it holds a colon: groups split by semicolons, each
        # 'env: user, user'. Splitting on commas alone made an account called
        # 'test: example-org', which no password can ever be set for.
        IFS=';' read -r -a _grp <<< "$au"
        for g in ${_grp+"${_grp[@]}"}; do
            case "$g" in *:*) g="${g#*:}" ;; esac
            IFS=',' read -r -a _want <<< "$g"
            for u in ${_want+"${_want[@]}"}; do
                u="$(trim "$u")"
                [ -n "$u" ] && [ "$u" != "$AUTH_ADMIN_USER" ] && ROW_ACCOUNTS+=("$u")
            done
        done
    done < <(conf_rows)

    if [ ${#ROW_ACCOUNTS[@]} -gt 0 ]; then
        mapfile -t ROW_ACCOUNTS < <(printf '%s\n' "${ROW_ACCOUNTS[@]}" | sort -u)
        for u in "${ROW_ACCOUNTS[@]}"; do
            grep -q "^${u}:" "$AUTH_USER_FILE" 2>/dev/null && continue
            print_action "Account '$u' is named by a row but does not exist: make it in the console's Users tab."
        done
    fi

    # A FIRST ADMIN PASSWORD IS GENERATED INTO THE VAULT, NOT ASKED
    # (login-store-decisions.md, decision 6). Stored first and set second: a
    # password set here but missing from the vault is one nobody knows. When
    # the vault cannot take it, add_auth_users.sh below asks as it always did.
    if ! grep -q "^${AUTH_ADMIN_USER}:" "$AUTH_USER_FILE" 2>/dev/null \
       && [ -f "$SCRIPT_DIR/person_entry.sh" ]; then
        ADMIN_PW="$(openssl rand -base64 18)"
        if [ -n "$ADMIN_PW" ] \
           && printf '%s\n' "$ADMIN_PW" | SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/person_entry.sh" --login "$AUTH_ADMIN_USER"; then
            if printf '%s\n' "$ADMIN_PW" | SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/manage_auth_users.sh" --add "$AUTH_ADMIN_USER"; then
                print_success "'$AUTH_ADMIN_USER' has a generated password. It is in 1Password, not shown here."
            fi
        fi
        unset ADMIN_PW
    fi

    ACCOUNT_SCRIPT="$REPO_ROOT/install_scripts/add_auth_users.sh"
    if [ -f "$ACCOUNT_SCRIPT" ]; then
        # Exit 1 means somebody is still without a password: either the operator
        # chose to carry on, or there was no terminal to ask at. Either way the
        # run is not complete, and that belongs in the summary rather than in a
        # line already scrolled past.
        if ! bash "$ACCOUNT_SCRIPT" --file "$AUTH_USER_FILE" "${EXPECTED_ACCOUNTS[@]}"; then
            FAILED+=("some login accounts have no password")
        fi
    else
        print_info "Cannot find $ACCOUNT_SCRIPT, so accounts were not checked."
        print_action "Run 'git submodule update --init' and try again, or add them by hand:"
        mapfile -t EXPECTED_ACCOUNTS < <(printf '%s\n' "${EXPECTED_ACCOUNTS[@]}" | sort -u)
        for u in "${EXPECTED_ACCOUNTS[@]}"; do
            print_action "  sudo htpasswd $AUTH_USER_FILE $u"
        done
    fi
fi

if [ ${#OPEN_NON_LIVE[@]} -gt 0 ]; then
    print_info "Published with no login, outside the '$DEFAULT_PUBLISH' environment:"
    for entry in "${OPEN_NON_LIVE[@]}"; do
        print_info "  - $entry"
    done
    print_info "A copy of a real site, reachable by anyone who guesses the name."
    print_action "If that is not intended, write it per environment in $SITES_CONF:"
    print_action "  AuthProtected = live:no, test:yes"
fi

if [ ${#NO_AUTH_USERS[@]} -gt 0 ]; then
    print_info "Protected, but with no AuthUsers, so only '$AUTH_ADMIN_USER' can enter:"
    for entry in "${NO_AUTH_USERS[@]}"; do
        print_info "  - $entry"
    done
    print_action "Fill the last field in $SITES_CONF to let the customer in as well."
fi

echo ""
[ ${#WRITTEN[@]} -gt 0 ]   && print_success "Written:   ${WRITTEN[*]}"
[ ${#UNCHANGED[@]} -gt 0 ] && print_success "Unchanged: ${UNCHANGED[*]}"

if [ ${#NO_CERT_YET[@]} -gt 0 ]; then
    print_info "HTTP only for now, no certificate yet:"
    for entry in "${NO_CERT_YET[@]}"; do
        print_info "  - $entry"
    done
    print_action "Run add_site_certificates.sh, then run this script again to add HTTPS."
fi

if [ ${#STOOD_DOWN[@]} -gt 0 ]; then
    print_info "Switched off and replaced, so nothing was published for: ${STOOD_DOWN[*]}"
fi
if [ ${#SKIPPED_NO_DOMAIN[@]} -gt 0 ]; then
    print_info "No Subdomain set, so not published: ${SKIPPED_NO_DOMAIN[*]}"
    print_action "Fill the Subdomain field in $SITES_CONF once DNS points here."
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Problems:"
    for entry in "${FAILED[@]}"; do
        print_error "  - $entry"
    done
    exit 1
fi

# RENDER_ONLY stops here. Nothing was written, so there is nothing to enable,
# configtest or reload: the answer is the list, and the caller reads it.
if [ "$RENDER_ONLY" = "1" ]; then
    if [ ${#WOULD_CHANGE[@]} -eq 0 ]; then
        print_success "No vhost would change."
    else
        print_status "${#WOULD_CHANGE[@]} vhost(s) would be rewritten:"
        for x in "${WOULD_CHANGE[@]}"; do print_status "  - $x"; done
    fi
    # One line per item for a caller that has to act on the list rather than
    # read it. Same shape as report_drift.sh's DRIFT_OUT.
    if [ -n "${RENDER_OUT:-}" ]; then
        : > "$RENDER_OUT"
        for x in "${WOULD_CHANGE[@]:-}"; do
            [ -n "$x" ] && printf 'UPDATE vhost   %s\n' "$x" >> "$RENDER_OUT"
        done
    fi
    exit 0
fi

if [ "$NEEDS_RELOAD" -eq 0 ]; then
    print_success "Nothing changed, Apache left running as is."
    exit 0
fi

# Never reload on a broken config: it takes every site on the box down at once
print_status "Testing Apache configuration..."

CONFIGTEST_LOG="$(mktemp)"
trap 'rm -f "$CONFIGTEST_LOG"' EXIT

if ! apache2ctl configtest >"$CONFIGTEST_LOG" 2>&1; then
    print_error "Apache configuration test failed, so Apache was NOT reloaded."
    print_action "The vhosts are on disk but not live. Output:"
    cat "$CONFIGTEST_LOG"
    print_action "Fix the config, then run: sudo systemctl reload apache2"
    exit 1
fi

print_success "Apache configuration is valid."

if systemctl is-active --quiet apache2; then
    if systemctl reload apache2; then
        print_success "Apache reloaded, the vhosts are live."
    else
        print_error "Apache reload failed. Check: systemctl status apache2"
        exit 1
    fi
else
    print_info "Apache is not running, so nothing was reloaded."
    print_action "Start it with: sudo systemctl start apache2"
fi

print_success "Apache vhosts configured."
