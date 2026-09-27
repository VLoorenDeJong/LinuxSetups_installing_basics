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
# Publish a row on a LAN port, so it can be looked at before it has a name.
#
# Until the drive swap, public DNS points at the OLD machine and Apache here
# routes by Host header, so no hostname reaches this box. A preview gives one
# environment of one row a plain port on the local subnet instead:
#
#     http://<this machine>:26901   test copy of example_org
#
# THE PORT IS DERIVED, NEVER CHOSEN
#
#     preview port = PREVIEW_PORT_BASE + the row's port in that environment
#
# so 6901 becomes 26901 and the real number is what is left after the leading
# 2. Nothing is allocated by hand, which is what keeps four environments of one
# row from colliding: their real ports already differ by the environment offset.
#
# A website row has no listener, so its Port field is not a port: it is the
# row's number in the four-digit scheme, and it exists so a preview can be
# derived. check_config.sh already counts it against every other row's ports,
# so a website taking 8901 stops an app being given it later.
#
# NOT A REPLACEMENT FOR TESTING THE REAL HOSTNAME
#
# A preview is plain HTTP on a port, so it exercises no certificate and no
# name-based routing. It is for looking at content, and for exercising the add
# and remove path on something real. The catch-all vhost is untouched.
#
# Safe to re-run: unchanged files are left alone, a preview that is no longer
# configured has its vhost removed and its firewall port closed, and Apache is
# only reloaded after configtest passes.
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

# LIST_URLS=1 prints every preview URL this script would publish, one per line,
# and writes nothing. The console reads it to show the links, and it is how a
# reader finds the ports without opening a vhost file.
LIST_URLS="${LIST_URLS:-0}"

# LIST_VHOSTS=1 prints the vhost filenames this script would write, one per
# line, and writes nothing. report_drift.sh reads it so it can tell a wanted
# preview from an orphan without re-implementing the port and AuthProtected
# rules that decide which ones exist. Same arrangement as REQUESTED_HOSTS for
# certificates: ask the generator, never guess what it would do.
LIST_VHOSTS="${LIST_VHOSTS:-0}"

# Either list mode writes nothing and needs no privilege.
LIST_ONLY=0
[ "$LIST_URLS" = "1" ] || [ "$LIST_VHOSTS" = "1" ] && LIST_ONLY=1

# RENDER_ONLY=1: build every preview vhost as a real run would, compare it with
# what is on disk, and write nothing. Same contract as add_app_vhosts.sh, and
# for the same reason: this file is the only place that knows what a preview
# vhost should contain, so it is the only honest answer to "would this change".
RENDER_ONLY="${RENDER_ONLY:-0}"
WOULD_CHANGE=()

# In list mode the URLs are the output, so everything else moves to stderr.
if [ "$LIST_ONLY" = "1" ]; then
    exec 3>&1 1>&2
fi

if [ "$LIST_ONLY" != "1" ] && [ "$RENDER_ONLY" != "1" ] && [ "$EUID" -ne 0 ]; then
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

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    print_action "Override with: sudo env SITES_CONF=/path/to/hostings.conf $0"
    exit 1
fi

if [ "$LIST_ONLY" != "1" ] && ! command -v a2ensite >/dev/null 2>&1; then
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

# The login, for a preview of a row that asks for one.
#
# Same shape as add_app_vhosts.sh writes for a plain-HTTP door, and its own
# cookie name for the same reason: a `secure` cookie is never sent back over
# plain HTTP, and reusing `session` would collide with the one :443 sets on the
# same hostname. The accounts are the row's own, plus the admin.
preview_auth_block() {
    local users="$1" login_page="$2" require_line="Require user" u

    IFS=',' read -r -a _pau <<< "$users"
    for u in ${_pau+"${_pau[@]}"}; do
        u="$(printf '%s' "$u" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$u" ] && require_line="$require_line $u"
    done
    require_line="$require_line $AUTH_ADMIN_USER"

    cat <<EOF

    # --- Login -------------------------------------------------------------
    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> must come FIRST.
    ProxyPass /${login_page}   !
    ProxyPass /do-login     !
    ProxyPass /logout       !
    ProxyPass /auth-assets  !

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
        SessionCookieName session_preview path=/;httponly
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
        SessionCookieName session_preview path=/;httponly
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY_FILE}
        Require all granted
    </Location>

    <Location /logout>
        SetHandler form-logout-handler
        AuthType None
        AuthFormLogoutLocation /${login_page}
        Session On
        SessionCookieName session_preview path=/;httponly
        SessionCryptoPassphraseFile ${AUTH_SESSION_KEY_FILE}
        Require all granted
    </Location>
EOF
}

# Who may enter in THIS environment. Same reading as add_app_vhosts.sh: a plain
# list is everyone everywhere, a list holding a colon is read per environment.
preview_users_in_env() {
    local list="$1" env="$2" grp k v
    case "$list" in
        *:*) ;;
        *) printf '%s' "$list"; return ;;
    esac
    IFS=';' read -r -a _pug <<< "$list"
    for grp in ${_pug+"${_pug[@]}"}; do
        k="$(printf '%s' "${grp%%:*}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        v="${grp#*:}"
        if [ "$k" = "$env" ]; then
            printf '%s' "$(printf '%s' "$v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            return
        fi
    done
    printf ''
}

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

AVAILABLE_DIR="/etc/apache2/sites-available"
# The same page add_app_vhosts.sh serves for a disabled website, so a preview
# port shows what the public address shows rather than the live site.
OFFLINE_ROOT="/var/www/under-construction"
PREVIEW_PREFIX="preview-"

# Which environments exist, and which one is the default. Same source as every
# other generator: a new environment must not need a script edited.
IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
for i in "${!ALL_ENVS[@]}"; do
    ALL_ENVS[$i]="$(trim "${ALL_ENVS[$i]}")"
done
DEFAULT_PUBLISH="${ALL_ENVS[0]}"

PREVIEW_PORT_BASE="$(conf_get PREVIEW_PORT_BASE 20000)"
APP_RUN_USER="$(conf_get APP_RUN_USER jenkins)"

# The account and PHP pool add_app_vhosts.sh gives each website row. The same
# rule, copied, so a preview runs a site's PHP where its real vhost does.
site_account() {
    local n
    n="site_$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_' '_')"
    if [ ${#n} -gt 32 ]; then
        n="${n:0:23}_$(printf '%s' "$1" | md5sum | cut -c1-8)"
    fi
    printf '%s' "$n"
}

# The rows that get a preview, by ApplicationName. Empty means none, which is
# the state a live machine should be in: a preview is a port with no name in
# front of it, and it exists for a machine that is not serving the public yet.
#
# An entry is a row name, optionally narrowed to one environment, optionally on
# a port of your choosing:
#
#   mvp_portfolio                every environment the row is in, port derived
#   mvp_portfolio:live           that environment only
#   mvp_portfolio:live:28002     that environment, on that exact port
#
# A bare name is what this file has always held, so nothing older breaks.
AUTH_USER_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
AUTH_SESSION_KEY_FILE="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
AUTH_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
AUTH_ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"
DEFAULT_PUBLISH_ENV="${ALL_ENVS[0]:-live}"

PREVIEW_ROWS_RAW="$(conf_get PREVIEW_ROWS "")"
declare -A WANTED=()     # row name -> 1, for the pre-flight
declare -A WANT_ALL=()   # row name -> 1 when no environment was named
declare -A WANT_ENV=()   # "row|env" -> auto, or the port to use
IFS=',' read -r -a _pr <<< "$PREVIEW_ROWS_RAW"
for _n in ${_pr+"${_pr[@]}"}; do
    _n="$(trim "$_n")"
    [ -z "$_n" ] && continue
    _row="${_n%%:*}"
    _rest="${_n#"$_row"}"
    _row="$(trim "$_row")"
    [ -z "$_row" ] && continue
    WANTED["$_row"]=1
    if [ -z "$_rest" ]; then
        WANT_ALL["$_row"]=1
        continue
    fi
    _rest="${_rest#:}"
    _env="$(trim "${_rest%%:*}")"
    _port="$(trim "${_rest#"${_rest%%:*}"}")"
    _port="${_port#:}"
    [ -z "$_env" ] && { WANT_ALL["$_row"]=1; continue; }
    WANT_ENV["${_row}|${_env}"]="${_port:-auto}"
done
unset _n _row _rest _env _port

# The subnet the preview ports are opened to. Derived from the default route so
# nothing has to be configured, and never widened: a preview has no login and
# no certificate, so the firewall is the only thing in front of it.
lan_cidr() {
    ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
        | sed -E 's/\.[0-9]+$/.0\/24/'
}

# Already open, scoped to this subnet? `ufw status` prints the rule as
# "26901/tcp   ALLOW   192.168.1.0/24", and a bare `allow 26901` would not match.
ufw_allows() {
    local port="$1" cidr="$2"
    printf '%s\n' "$UFW_STATUS" | awk -v p="$port" -v c="$cidr" '
        $0 ~ "^" p "/tcp" && index($0, c) { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

MACHINE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[ -z "$MACHINE_IP" ] && MACHINE_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

WRITTEN=()
UNCHANGED=()
REMOVED=()
SKIPPED_AUTH=()
PROTECTED=()
SKIPPED_NO_PORT=()
FAILED=()
URLS=()
declare -A GENERATED=()
NEEDS_RELOAD=0

# =============================================================================
# Pre-flight: every name in PREVIEW_ROWS must be a row that can have one
# =============================================================================
ERRORS=()
declare -A ROW_TYPE=()
while IFS='|' read -r type name port path sub datasource options authprotected \
                      siterepo sitebranch rowenvs authusers repomode runtime enabled; do
    _trim type "$type"; _trim name "$name"
    [ -z "$name" ] && continue
    ROW_TYPE["$name"]="$type"
done < <(conf_rows)

GONE=()
for want in "${!WANTED[@]}"; do
    if [ -z "${ROW_TYPE[$want]:-}" ]; then
        # The row was deleted while its name stayed in PREVIEW_ROWS. A preview
        # for a row that no longer exists is a removal, not a typo: it is
        # dropped here and its vhost and port are taken away below, exactly as
        # unticking the preview would have done.
        GONE+=("$want")
        unset "WANTED[$want]"
        continue
    fi
    case "${ROW_TYPE[$want]}" in
        app|website|php|docroot) ;;
        *) ERRORS+=("PREVIEW_ROWS names '$want', which is a ${ROW_TYPE[$want]} row. Only app and website rows can be previewed.") ;;
    esac
done

if [ ${#GONE[@]} -gt 0 ]; then
    print_header "Preview ports"
    for g in "${GONE[@]}"; do
        print_info "PREVIEW_ROWS names '$g', which is no longer a row. Its preview is removed."
    done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_header "Preview ports"
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

# =============================================================================
# One vhost per row per environment
# =============================================================================
build_previews() {
    local type name port path sub datasource options authprotected
    local siterepo sitebranch rowenvs authusers repomode runtime enabled
    local env env_upper offset env_port preview_port web_root doc_root
    local file label body content want offline_fallback

    while IFS='|' read -r type name port path sub datasource options authprotected \
                          siterepo sitebranch rowenvs authusers repomode runtime enabled; do
        _trim type "$type"
        _trim name "$name"
        [ -z "$name" ] && continue
        [ -z "${WANTED[$name]:-}" ] && continue

        # A preview must show what the public address shows. Without this a
        # switched-off website stayed fully served on its preview port, from
        # its real document root, while the public vhost said it was off.
        _trim enabled "$enabled"
        enabled="${enabled,,}"
        if [ -z "$enabled" ] || [ "$enabled" = "-" ]; then enabled="yes"; fi

        _trim port "$port"
        _trim path "$path"
        _trim authprotected "$authprotected"
        _trim authusers "$authusers"
        authprotected="${authprotected,,}"

        # A row with no port can still be previewed, on a port it names itself.
        # A website's Port is its number in the scheme and nothing listens on
        # it, so requiring one meant a site with no number could never be
        # looked at before the drive swap. It is refused below, per
        # environment, only where PREVIEW_ROWS asks for `auto` and there is
        # therefore nothing to derive from.
        if [ -z "$port" ] && [ -n "${WANT_ALL[$name]:-}" ]; then
            SKIPPED_NO_PORT+=("$name")
            continue
        fi

        for env in "${ALL_ENVS[@]}"; do
            row_in_env "$rowenvs" "$env" || continue

            # Named environments win; a bare name in PREVIEW_ROWS means all.
            want="${WANT_ENV[${name}|${env}]:-}"
            if [ -z "$want" ]; then
                [ -n "${WANT_ALL[$name]:-}" ] || continue
                want="auto"
            fi
            env_upper="${env^^}"

            # A protected row keeps its protection here: the preview gets the same
            # login, over plain HTTP, with the row's own accounts. A row that asks
            # for no login is published open, which is what a preview port is for.
            preview_auth=""
            if auth_in_env "$authprotected" "$env"; then
                preview_login_page="login.html"
                [ "$env" != "$DEFAULT_PUBLISH_ENV" ] && preview_login_page="login-${env}.html"
                if [ ! -f "${AUTH_WEB_ROOT}/${preview_login_page}" ]; then
                    FAILED+=("${name}/${env} (no login page at ${AUTH_WEB_ROOT}/${preview_login_page}, run add_app_vhosts.sh first)")
                    continue
                fi
                preview_auth="$(preview_auth_block \
                    "$(preview_users_in_env "$authusers" "$env")" "$preview_login_page")"
                PROTECTED+=("$name/$env")
            fi

            _conf_get offset "${env_upper}_PORT_OFFSET" 0
            env_port=$((port + offset))
            if [ "$want" = "auto" ] && [ -z "$port" ]; then
                SKIPPED_NO_PORT+=("$name/$env")
                continue
            elif [ "$want" = "auto" ]; then
                preview_port=$((PREVIEW_PORT_BASE + env_port))
            elif [[ "$want" =~ ^[0-9]+$ ]] && [ "$want" -ge 1024 ] && [ "$want" -le 65535 ]; then
                preview_port="$want"
            else
                FAILED+=("${name}/${env} (PREVIEW_ROWS asks for port '$want', which is not a usable port)")
                continue
            fi

            # Apache would bind this on every address, including the one the
            # service already listens on, and the bind would fail.
            if [ "$preview_port" = "$env_port" ]; then
                FAILED+=("${name}/${env} (preview port $preview_port is the service's own port)")
                continue
            fi

            label="${name}/${env}"
            URLS+=("http://${MACHINE_IP:-<this machine>}:${preview_port}/    ${label}")

            case "$type" in
                app)
                    body="$(cat <<EOF
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${env_port}/
    ProxyPassReverse / http://127.0.0.1:${env_port}/

    RequestHeader set X-Forwarded-Proto expr=%{REQUEST_SCHEME}
    RequestHeader set X-Forwarded-For "%{REMOTE_ADDR}s"

    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteRule /(.*) ws://127.0.0.1:${env_port}/\$1 [P,L]
EOF
)"
                    ;;
                website|php|docroot)
                    _conf_get web_root "WEB_ROOT_${env_upper}" ""
                    if [ -z "$web_root" ]; then
                        FAILED+=("$label (no WEB_ROOT_${env_upper})")
                        continue
                    fi
                    doc_root="${web_root%/}/${path#/}"
                    site_acct="$(site_account "$name")"
                    offline_fallback=""
                    if [ "$enabled" = "no" ]; then
                        # Decided before the directory check, exactly as
                        # add_app_vhosts.sh does it: a switched-off site does
                        # not need its real root to exist.
                        doc_root="$OFFLINE_ROOT"
                        offline_fallback="
    FallbackResource /index.html"
                    # Not created here. add_app_vhosts.sh owns the document
                    # root and puts a placeholder in it; a preview pointing at
                    # a directory that script has not made yet is a sign the
                    # real vhost is missing, and hiding that helps nobody.
                    elif [ ! -d "$doc_root" ]; then
                        FAILED+=("$label (no document root at $doc_root, run add_app_vhosts.sh first)")
                        continue
                    fi
                    body="$(cat <<EOF
    DocumentRoot ${doc_root}${offline_fallback}

    <Directory ${doc_root}>
        Options -Indexes +FollowSymLinks +IncludesNOEXEC
        AddOutputFilter INCLUDES .shtml
        # The same limits and the same pool as the real vhost: see
        # add_app_vhosts.sh, which owns both.
        AllowOverride None
        AllowOverrideList DirectoryIndex FallbackResource ErrorDocument Redirect RedirectMatch RedirectPermanent RedirectTemp Header ExpiresActive ExpiresByType ExpiresDefault AddType AddCharset AddDefaultCharset
        Require all granted
        <FilesMatch "\.php\$">
            SetHandler "proxy:unix:/run/php/${site_acct}.sock|fcgi://${site_acct}"
        </FilesMatch>
    </Directory>

    RedirectMatch 404 /\.git
EOF
)"
                    ;;
                *)
                    FAILED+=("$label (cannot preview a $type row)")
                    continue
                    ;;
            esac

            file="${AVAILABLE_DIR}/${PREVIEW_PREFIX}${name}-${env}.conf"
            GENERATED["$(basename "$file")"]="$preview_port"

            content="$(cat <<EOF
# Generated by add_preview_vhosts.sh from /etc/hostings/hostings.conf
# Do not edit by hand: the next run overwrites it. Edit PREVIEW_ROWS instead.
#
# ${label}, reachable on this machine's LAN address at port ${preview_port}.
# The real port for this environment is ${env_port}; the preview number is
# that plus ${PREVIEW_PORT_BASE}.
#
# Plain HTTP, no certificate, no login. The firewall scopes it to the local
# subnet and that is the only thing in front of it.
Listen ${preview_port}

<VirtualHost *:${preview_port}>
    ServerName preview-${name}-${env}

${preview_auth}

${body}

    ErrorLog \${APACHE_LOG_DIR}/preview-${name}-${env}-error.log
    CustomLog \${APACHE_LOG_DIR}/preview-${name}-${env}-access.log combined
</VirtualHost>
EOF
)"

            [ "$LIST_ONLY" = "1" ] && continue

            # Compare and report, write nothing. The same comparison the real
            # run makes below.
            if [ "$RENDER_ONLY" = "1" ]; then
                if [ ! -f "$file" ]; then
                    WOULD_CHANGE+=("$label (new)")
                elif [ "$(cat "$file")" != "$content" ]; then
                    WOULD_CHANGE+=("$label")
                fi
                continue
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
            [ -e "/etc/apache2/sites-enabled/$(basename "$file")" ] ||
                a2ensite "$(basename "$file")" >/dev/null 2>&1 || FAILED+=("$label (a2ensite failed)")
        done
    done < <(conf_rows)
}

# =============================================================================
# Remove the previews that are no longer asked for
#
# The whole point of a preview being cheap to add is that it is cheap to take
# away again, so this runs on every pass rather than behind a flag. A vhost
# left enabled holds its Listen port open with nothing behind it.
# =============================================================================
prune_previews() {
    local file base port cidr
    cidr="$(lan_cidr)"

    for file in "${AVAILABLE_DIR}/${PREVIEW_PREFIX}"*.conf; do
        [ -e "$file" ] || continue
        base="$(basename "$file")"
        [ -n "${GENERATED[$base]:-}" ] && continue

        port="$(awk '/^Listen /{print $2; exit}' "$file")"
        a2dissite "$base" >/dev/null 2>&1 || true
        rm -f "$file"
        NEEDS_RELOAD=1
        REMOVED+=("${base#$PREVIEW_PREFIX}")

        # Deleted the way it was added: a rule scoped to a subnet does not
        # match `delete allow <port>/tcp`.
        if [ -n "$port" ] && [ -n "$cidr" ] && command -v ufw >/dev/null 2>&1; then
            ufw delete allow from "$cidr" to any port "$port" proto tcp >/dev/null 2>&1 || true
        fi
    done
}

open_ports() {
    local cidr base port
    command -v ufw >/dev/null 2>&1 || return 0
    # Read once: every `ufw status` is a Python start, and ufw_allows asks per port.
    UFW_STATUS="$(ufw status 2>/dev/null || true)"
    grep -q "Status: active" <<< "$UFW_STATUS" || return 0

    cidr="$(lan_cidr)"
    if [ -z "$cidr" ]; then
        print_info "Could not work out the local subnet, so no preview port was opened."
        return 0
    fi

    for base in "${!GENERATED[@]}"; do
        port="${GENERATED[$base]}"
        if ! ufw_allows "$port" "$cidr"; then
            ufw allow from "$cidr" to any port "$port" proto tcp >/dev/null 2>&1
            print_success "Opened $port to $cidr only."
        fi
    done
}

for mod in proxy proxy_http proxy_wstunnel rewrite headers include; do
    [ "$RENDER_ONLY" = "1" ] && break
    [ "$LIST_ONLY" = "1" ] && break
    [ -e "/etc/apache2/mods-enabled/${mod}.load" ] || a2enmod "$mod" >/dev/null 2>&1 || true
done

build_previews

if [ "$LIST_URLS" = "1" ]; then
    for u in ${URLS+"${URLS[@]}"}; do printf '%s\n' "$u" >&3; done
    exit 0
fi

if [ "$LIST_VHOSTS" = "1" ]; then
    for b in ${!GENERATED[@]}; do printf '%s\n' "$b" >&3; done
    exit 0
fi


# RENDER_ONLY stops before prune_previews: nothing was written, so there is
# nothing to prune, enable or reload. The list is the answer.
if [ "$RENDER_ONLY" = "1" ]; then
    if [ ${#WOULD_CHANGE[@]} -eq 0 ]; then
        print_success "No preview vhost would change."
    else
        print_status "${#WOULD_CHANGE[@]} preview vhost(s) would be rewritten:"
        for x in "${WOULD_CHANGE[@]}"; do print_status "  - $x"; done
    fi
    if [ -n "${RENDER_OUT:-}" ]; then
        : > "$RENDER_OUT"
        for x in "${WOULD_CHANGE[@]:-}"; do
            [ -n "$x" ] && printf 'UPDATE preview %s\n' "$x" >> "$RENDER_OUT"
        done
    fi
    exit 0
fi

prune_previews

print_header "Preview ports"

if [ -z "$PREVIEW_ROWS_RAW" ]; then
    print_status "PREVIEW_ROWS is empty, so no row is published on a LAN port."
fi

if [ "$NEEDS_RELOAD" = "1" ]; then
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2
    else
        print_error "Apache rejected the preview config, so nothing was loaded:"
        apache2ctl configtest 2>&1 | tail -20
        for base in "${!GENERATED[@]}"; do a2dissite "$base" >/dev/null 2>&1 || true; done
        systemctl reload apache2 2>/dev/null || true
        exit 1
    fi
fi

open_ports

for r in ${WRITTEN+"${WRITTEN[@]}"};   do print_success "Published $r"; done
for r in ${UNCHANGED+"${UNCHANGED[@]}"}; do print_status  "Already published: $r"; done
for r in ${REMOVED+"${REMOVED[@]}"};   do print_success "Removed and port closed: ${r%.conf}"; done
for r in ${PROTECTED+"${PROTECTED[@]}"}; do
    print_status "$r is published behind the same login as the site."
done
for r in ${SKIPPED_NO_PORT+"${SKIPPED_NO_PORT[@]}"}; do
    print_info "$r has no Port, so there is no number to derive a preview from."
    print_action "   Give it its number from the four-digit scheme. Nothing will listen on it."
done
for r in ${FAILED+"${FAILED[@]}"};    do print_error   "$r"; done

if [ ${#URLS[@]} -gt 0 ]; then
    echo ""
    print_header "Open these"
    for u in "${URLS[@]}"; do echo "   $u"; done
fi

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Some previews were not published."
    exit 1
fi
print_success "Preview ports are up to date."
