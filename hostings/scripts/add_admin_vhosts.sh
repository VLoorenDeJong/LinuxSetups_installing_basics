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
# admin.<domain>: the console, on every domain this machine serves.
#
# EVERY DOMAIN GETS ONE, WITH NO CONDITIONS. The owner, 2026-09-10, after an
# earlier version derived it three conditions deep from who owned which row.
#
# The flip is what makes it simple: NARROW THE DOOR, NOT THE LIST. `Require
# user` admits only the names that hold a role, so publishing a name nobody may
# use costs a vhost and nothing else. Nothing anywhere records which domains
# have an admin page, because they all do.
#
# A domain leaves the config -> its vhost is reported orphaned, and --prune
# removes it. That is the only reason one ever goes.
#
# IT SERVES THE SAME PAGE AS THE LAN CONSOLE. Not a copy, not a second console:
# the same DocumentRoot, the same password file, the same session key. What a
# person sees is decided by their role and by the sixteenth field of each row,
# inside index.php, exactly as it is on port 10001.
#
# WHY THAT IS SAFE TO PUT ON A PUBLIC NAME, stated plainly because it is the
# security-relevant claim in this file: `Require user` admits ONLY the names
# that hold a role, so a password that exists for a protected vhost, a preview
# or a share is not a key to this page. A name that does get in is still not
# trusted: index.php serves a limited admin only their own rows and refuses
# every write they may not do. Those refusals are in the PHP and in the scripts
# behind it, never in what the page chooses to draw.
#
# And a name with NO CERTIFICATE gets a holding page rather than a login form,
# because a password typed over plain HTTP crosses the network in clear.
#
#   add_admin_vhosts.sh --list     which names should exist, one per line
#   add_admin_vhosts.sh --check    what would change, writes nothing
#   add_admin_vhosts.sh            write them
#   add_admin_vhosts.sh --prune    and remove the ones whose domain has gone
#
# --list is why the domain list lives here rather than in three places:
# add_site_certificates.sh needs the same answer to request a certificate, and
# report_drift.sh needs it to say what is missing.
#
# Safe to re-run: an unchanged vhost is left alone, and Apache is reloaded only
# after configtest passes.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[1;35m=== %s ===\033[0m\n" "$1"; }

MODE="apply"
PRUNE=0

usage() {
    echo "Usage: sudo bash add_admin_vhosts.sh [--list] [--check] [--prune] [--debug]"
    echo ""
    echo "  --list    print the admin hostnames that should exist, one per line"
    echo "  --check   report what would change, write nothing"
    echo "  --prune   remove a vhost whose domain no longer has an owner with"
    echo "            a role. Without it they are only reported."
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --list)      MODE="list" ;;
        --check)     MODE="check" ;;
        --prune)     PRUNE=1 ;;
        -h|--help)   usage ;;
        *)           print_error "Unknown option: $arg"; usage ;;
    esac
done

if [ "$MODE" = "apply" ] && [ "$EUID" -ne 0 ]; then
    print_error "This writes Apache config, so it needs root."
    print_action "Run: sudo bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"

conf_get() {
    local key="$1" default="${2:-}" value
    [ -f "$SITES_CONF" ] || { echo "$default"; return; }
    # tr -d '\r' before anything else: a value is the last thing on its line, so
    # a CRLF file leaves the carriage return inside it.
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | tr -d '\r' | tail -1 | cut -d= -f2- | sed 's/#.*//' | xargs)"
    [ -z "$value" ] && value="$default"
    echo "$value"
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
if [ -z "$BASE_DOMAIN" ]; then
    print_error "No BASE_DOMAIN in $SITES_CONF"
    print_action "Add: BASE_DOMAIN = example.com"
    exit 1
fi
AUTH_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
META_FILE="$(conf_get AUTH_USER_META /etc/apache2/.htpasswd-progress.meta)"
# The same paths add_hosting_manager.sh uses, read the same way, so the two
# cannot drift apart. WEB_ROOT is fixed there, not a config key.
WEB_ROOT="/var/www/hosting-manager"
# The page's own PHP pool, written by add_hosting_manager.sh. Item 146.
PAGE_USER="hosting-manager"
POOL_SOCKET="/run/php/${PAGE_USER}.sock"
AUTH_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
SESSION_KEY="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
LOGIN_PAGE="login.html"
LE_DIR="/etc/letsencrypt/live"

# The names that hold a role. Same list as the LAN console, from the same one
# place, so the two doors cannot disagree about who may come in.
ROLE_HOLDERS="$(bash "$SCRIPT_DIR/manage_auth_users.sh" --role-holders 2>/dev/null || true)"
[ -z "$ROLE_HOLDERS" ] && ROLE_HOLDERS="$(conf_get AUTH_ADMIN_USER admin)"

AVAILABLE_DIR="/etc/apache2/sites-available"
ENABLED_DIR="/etc/apache2/sites-enabled"
ADMIN_PREFIX="admin-"

# -----------------------------------------------------------------------------
# Every domain this machine serves, one admin.<domain> each. Item 105.
#
# NO CONDITIONS. The owner, 2026-09-10, flipping an earlier three-deep derivation
# on its head, and it is simpler because the DOOR is narrow rather than the
# list: `Require user` admits only the names that hold a role, so publishing a
# name nobody may use costs a vhost and nothing else.
#
# What the earlier version did, for the record, because its reasoning was not
# wrong so much as unnecessary: it published a domain only when one of its rows
# named an Owner who held a role, and pruned the vhost again when either
# changed. That is three conditions to get wrong, a prune that deletes a live
# certificate's vhost, and a rule nobody can predict from the config.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# The registrable domain a row answers on, which is what the subdomain is built
# from. The same three shapes _resolve_host() reads in add_app_vhosts.sh, and
# only the domain half of them: an environment prefix makes no difference to
# which domain this is.
#
#   =other.nl   -> other.nl
#   @ or @label -> BASE_DOMAIN
#   shop        -> BASE_DOMAIN
#   empty       -> nothing is published, so no domain
# -----------------------------------------------------------------------------
domain_of() {
    local sub="$1"
    sub="${sub//$'\r'/}"
    sub="$(printf '%s' "$sub" | xargs)"
    case "$sub" in
        ''|-) return 1 ;;
        =*)   printf '%s' "${sub#=}" ;;
        *)    printf '%s' "$BASE_DOMAIN" ;;
    esac
    return 0
}

# -----------------------------------------------------------------------------
# Every domain, one name per line, and the only place that list is built.
# -----------------------------------------------------------------------------
admin_hostnames() {
    local seen=()
    while IFS='|' read -r type name port path sub datasource options auth repo \
                          branch rowenvs authusers repomode runtime enabled owner; do
        # A mailbox has no vhost and no document root, so it names no domain
        # this machine serves.
        type="$(printf '%s' "${type//$'\r'/}" | xargs)"
        [ "$type" = "mailbox" ] && continue

        local dom
        dom="$(domain_of "$sub")" || continue
        [ -z "$dom" ] && continue

        # A domain reached by four rows is still one subdomain.
        local already=0 s
        for s in ${seen+"${seen[@]}"}; do [ "$s" = "$dom" ] && already=1; done
        [ "$already" = "1" ] && continue
        seen+=("$dom")
        echo "admin.${dom}"
    done < <(grep -E '^[[:space:]]*[A-Za-z]+[[:space:]]*\|' "$SITES_CONF" 2>/dev/null \
             | grep -vE '^[[:space:]]*(PANEL|SHARE)[[:space:]]*=')
}

if [ "$MODE" = "list" ]; then
    admin_hostnames
    exit 0
fi

print_header "The console on every domain that has somebody to use it"
print_status "Config:      $SITES_CONF"
print_status "Serving:     $WEB_ROOT"

# -----------------------------------------------------------------------------
# Pre-flight: everything this needs before it writes anything.
# -----------------------------------------------------------------------------
FAIL=0
if [ ! -d "$WEB_ROOT" ]; then
    print_error "No console at $WEB_ROOT, so there is nothing to serve."
    print_action "Run: sudo bash $SCRIPT_DIR/add_hosting_manager.sh"
    FAIL=1
fi
if [ ! -f "$AUTH_FILE" ]; then
    print_error "No password file at $AUTH_FILE, so nobody could sign in."
    print_action "Run: sudo htpasswd -c -B $AUTH_FILE admin"
    FAIL=1
fi
if [ ! -f "$SESSION_KEY" ]; then
    print_error "No session key at $SESSION_KEY, so the login form cannot work."
    print_action "Run: sudo bash $SCRIPT_DIR/add_hosting_manager.sh"
    FAIL=1
fi
[ "$FAIL" = "1" ] && exit 1

WANT=()
while read -r h; do [ -n "$h" ] && WANT+=("$h"); done < <(admin_hostnames)

if [ "${#WANT[@]}" -eq 0 ]; then
    print_info "No domain has a row whose Owner can sign in, so there is nothing to serve."
    print_info "Give a row an Owner in the console, and that domain gets admin.<domain>."
fi

# -----------------------------------------------------------------------------
# One vhost per name. The certificate decides whether it is :443 or :80: a name
# with no certificate yet is served on plain HTTP rather than refused, because
# the certificate is requested by add_site_certificates.sh AFTER this runs and
# a chicken-and-egg here would mean neither ever happened.
# -----------------------------------------------------------------------------
vhost_for() {
    local host="$1" cert_dir="${LE_DIR}/$1"
    local have_cert=0
    [ -f "${cert_dir}/fullchain.pem" ] && [ -f "${cert_dir}/privkey.pem" ] && have_cert=1

    local body
    body="$(cat <<EOF
    DocumentRoot ${WEB_ROOT}
    ServerName ${host}

    <Directory ${WEB_ROOT}>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
        # The page's own pool, never the machine-wide one that runs as www-data.
        <FilesMatch "\.php\$">
            SetHandler "proxy:unix:${POOL_SOCKET}|fcgi://${PAGE_USER}"
        </FilesMatch>
    </Directory>

    Alias /${LOGIN_PAGE} ${AUTH_ROOT}/${LOGIN_PAGE}
    Alias /auth-assets ${AUTH_ROOT}
    <Directory ${AUTH_ROOT}>
        Require all granted
    </Directory>

    # ORDER IS LOAD BEARING: <Location> blocks merge in file order and the LAST
    # match wins, so the general <Location /> comes FIRST and the exceptions
    # after it. Reversed, the login page itself requires a login and loops.
    <Location />
        AuthType form
        AuthName "Sign in"
        AuthFormProvider file
        AuthUserFile ${AUTH_FILE}
        AuthFormLoginRequiredLocation /${LOGIN_PAGE}
        # No KeptBodySize: see add_hosting_manager.sh, it segfaults Apache on a slow POST.
        Session On
        SessionCookieName manager_https path=/;httponly;secure
        SessionCryptoPassphraseFile ${SESSION_KEY}
        # Every account in the password file. What each of them SEES is decided
        # inside index.php by their role and by each row's Owner, and every
        # write they are not allowed is refused there too.
        Require user ${ROLE_HOLDERS}
    </Location>

    <Location /${LOGIN_PAGE}>
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
        AuthUserFile ${AUTH_FILE}
        AuthFormLoginRequiredLocation /${LOGIN_PAGE}
        AuthFormLoginSuccessLocation /
        Session On
        SessionCookieName manager_https path=/;httponly;secure
        SessionCryptoPassphraseFile ${SESSION_KEY}
        Require all granted
    </Location>
EOF
)"

    # The marker report_drift.sh looks for. Without it this file is invisible to
    # the drift report, so a stale one would never be reported.
    echo "# Generated by add_admin_vhosts.sh from /etc/hostings/hostings.conf"
    echo "# Do not edit by hand: the next run overwrites it. Edit the config instead."
    echo "#"
    echo "# DERIVED, never configured: every domain this machine serves gets one."
    echo "# The domain leaving the config is the only reason this file goes."
    echo ""
    if [ "$have_cert" = "1" ]; then
        # The plain-HTTP half stays, and only to send a browser to the secure
        # one. A person who types the name without https must not get a login
        # form on port 80: the password would go over the wire in clear.
        cat <<EOF
<VirtualHost *:80>
    ServerName ${host}
    Redirect permanent / https://${host}/
</VirtualHost>

<VirtualHost *:443>
${body}

    SSLEngine on
    SSLCertificateFile ${cert_dir}/fullchain.pem
    SSLCertificateKeyFile ${cert_dir}/privkey.pem
</VirtualHost>
EOF
    else
        # NO CERTIFICATE YET, so this name gets NO LOGIN FORM. A password typed
        # into a plain-HTTP form crosses the network in clear, and publishing
        # every domain unconditionally means this case happens by itself rather
        # than because somebody chose it.
        #
        # A holding page instead, with no auth block at all: nothing to type, so
        # nothing to intercept. The next run rewrites this file as :443 once
        # add_site_certificates.sh has issued the certificate.
        cat <<EOF
# No certificate for ${host} yet, so this serves a holding page and NOT a login
# form: a password typed over plain HTTP crosses the network in clear.
# add_site_certificates.sh requests one; the next run of this script rewrites
# this file as :443 the moment it exists.
<VirtualHost *:80>
    ServerName ${host}
    DocumentRoot ${WEB_ROOT}

    # No AuthType, no Location, no password file. There is nothing here to sign
    # in to until the certificate arrives.
    ErrorDocument 503 "This admin page is not ready yet: it has no certificate, and a login over plain HTTP would send the password in clear. It starts working once the certificate is issued."
    Redirect 503 /
</VirtualHost>
EOF
    fi
}

ADDED=0; UPDATED=0; SAME=0; ORPHANED=0; REMOVED=0
CHANGED=0

for host in ${WANT+"${WANT[@]}"}; do
    file="${AVAILABLE_DIR}/${ADMIN_PREFIX}${host}.conf"
    new="$(vhost_for "$host")"
    if [ -f "$file" ] && [ "$(cat "$file")" = "$new" ]; then
        SAME=$((SAME + 1))
        continue
    fi
    what="add"; [ -f "$file" ] && what="update"
    if [ "$MODE" = "check" ]; then
        [ "$what" = "add" ] && { print_info "would ADD    ${host}"; ADDED=$((ADDED + 1)); } \
                            || { print_info "would UPDATE ${host}"; UPDATED=$((UPDATED + 1)); }
        continue
    fi
    printf '%s\n' "$new" > "$file"
    ln -sf "$file" "${ENABLED_DIR}/${ADMIN_PREFIX}${host}.conf"
    CHANGED=1
    if [ "$what" = "add" ]; then
        ADDED=$((ADDED + 1)); print_success "Serving ${host}"
    else
        UPDATED=$((UPDATED + 1)); print_success "Rewrote ${host}"
    fi
done

# -----------------------------------------------------------------------------
# A vhost with no reason left to exist. Reported always, removed only with
# --prune: a domain that lost its Owner this morning may be getting it back
# this afternoon, and deleting a certificate's vhost is not a thing to do on a
# guess.
# -----------------------------------------------------------------------------
for file in "${AVAILABLE_DIR}/${ADMIN_PREFIX}"*.conf; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    host="${base#${ADMIN_PREFIX}}"; host="${host%.conf}"
    keep=0
    for w in ${WANT+"${WANT[@]}"}; do [ "$w" = "$host" ] && keep=1; done
    [ "$keep" = "1" ] && continue
    ORPHANED=$((ORPHANED + 1))
    if [ "$PRUNE" = "1" ] && [ "$MODE" = "apply" ]; then
        rm -f "$file" "${ENABLED_DIR}/${base}"
        REMOVED=$((REMOVED + 1)); CHANGED=1
        print_success "Removed ${host}: no row on that domain has an Owner who can sign in."
    else
        print_info "ORPHANED ${host}: no row on that domain has an Owner who can sign in."
        print_action "Remove it with: sudo bash $0 --prune"
    fi
done

if [ "$MODE" = "check" ]; then
    print_info "Would add $ADDED, update $UPDATED, leave $SAME, and $ORPHANED are orphaned."
    exit 0
fi

if [ "$CHANGED" = "1" ]; then
    if apache2ctl configtest 2>&1 | grep -qv "Syntax OK"; then
        if ! apache2ctl configtest >/dev/null 2>&1; then
            print_error "Apache refused the config, so it was NOT reloaded."
            apache2ctl configtest 2>&1 | tail -5
            print_action "Fix the error above, then run: sudo systemctl reload apache2"
            exit 1
        fi
    fi
    systemctl reload apache2
    print_success "Apache reloaded."
fi

print_success "Admin pages: $ADDED added, $UPDATED rewritten, $SAME unchanged, $REMOVED removed."
[ "$ORPHANED" -gt 0 ] && [ "$PRUNE" != "1" ] && \
    print_info "$ORPHANED are orphaned and were left alone. --prune removes them."
exit 0
