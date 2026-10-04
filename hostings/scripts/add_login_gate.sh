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
# The login gate: what every page with a login in front of it stands on.
#
#   the login pages    /var/www/auth, LinuxBasics' plain ones with the
#                      machine's own from /etc/hostings/apache/www/auth on top
#   the Apache modules mod_auth_form and the four it needs
#   the session key    32 random bytes, generated, never shown
#   the admin account  AUTH_ADMIN_USER in AUTH_USER_FILE
#   the throttle       fail2ban jail login-gate: wrong passwords slow down
#
# Needs no domain and no certificate, so a LAN-only machine can put a login in
# front of its machine pages (add_panel_vhosts.sh) without the public half of
# the stack. add_app_vhosts.sh runs this too, for rows with AuthProtected.
#
# The admin password goes into the vault when person_entry.sh can reach one,
# and is asked at the keyboard otherwise.
#
# Usage:
#   sudo bash add_login_gate.sh
#
# Exit codes:
#   0  the gate is complete
#   1  something is missing; what and how to fix it was printed
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

case "${1:-}" in
    "") ;;
    -h|--help) sed -n '19,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print_error "Unknown option: $1"; exit 1 ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This writes Apache's login files, so it needs root."
    print_action "Run: sudo bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local key="$1" default="${2:-}" value
    [ -f "$SITES_CONF" ] || { echo "$default"; return; }
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | tr -d '\r' | tail -1 | cut -d= -f2- | sed 's/#.*//' | xargs)"
    [ -z "$value" ] && value="$default"
    echo "$value"
}

AUTH_USER_FILE="$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)"
AUTH_SESSION_KEY_FILE="$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)"
AUTH_WEB_ROOT="$(conf_get AUTH_WEB_ROOT /var/www/auth)"
AUTH_ADMIN_USER="$(conf_get AUTH_ADMIN_USER admin)"
BASICS_AUTH="$REPO_ROOT/install_scripts/assets/auth"
AUTH_SRC="/etc/hostings/apache/www/auth"
ACCOUNT_SCRIPT="$REPO_ROOT/install_scripts/add_auth_users.sh"

print_header "Login gate"
print_status "Pages:       $AUTH_WEB_ROOT"
print_status "Accounts:    $AUTH_USER_FILE, admin '$AUTH_ADMIN_USER'"
print_status "Session key: $AUTH_SESSION_KEY_FILE"

# --- Pre-flight --------------------------------------------------------------
ERRORS=()
command -v apache2ctl >/dev/null 2>&1 \
    || ERRORS+=("Apache is not installed. Install it first: sudo bash $REPO_ROOT/install_scripts/add_apache_webserver.sh")
[ -d "$BASICS_AUTH" ] || [ -d "$AUTH_SRC" ] \
    || ERRORS+=("No login pages in $BASICS_AUTH or $AUTH_SRC. Run: git submodule update --init")
[ -f "$ACCOUNT_SCRIPT" ] \
    || ERRORS+=("$ACCOUNT_SCRIPT is missing, so no account could be made. Run: git submodule update --init")
if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi
print_success "Pre-flight passed."

FAILED=()

# --- The login pages ---------------------------------------------------------
# Shared first and local on top: a machine carries only the pages it changed.
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

# --- The modules -------------------------------------------------------------
NEEDS_RELOAD=0
loaded_mods="$(apache2ctl -M 2>/dev/null || true)"
for mod in auth_form session session_cookie session_crypto request; do
    grep -q "${mod}_module" <<< "$loaded_mods" && continue
    if a2enmod "$mod" >/dev/null 2>&1; then
        print_success "Enabled mod_${mod}"
        NEEDS_RELOAD=1
    else
        print_error "Could not enable mod_${mod}"
        FAILED+=("mod_${mod}")
    fi
done

# --- The session key ---------------------------------------------------------
# Whoever holds it can forge a session for every protected page, so it is
# generated here, never in the repo and never printed.
if [ -f "$AUTH_SESSION_KEY_FILE" ]; then
    print_success "Session key already there."
elif ( umask 077; openssl rand -base64 32 > "$AUTH_SESSION_KEY_FILE" ) 2>/dev/null; then
    chown root:root "$AUTH_SESSION_KEY_FILE" 2>/dev/null || true
    print_success "Generated a session key at $AUTH_SESSION_KEY_FILE"
else
    print_error "Could not generate $AUTH_SESSION_KEY_FILE"
    print_action "Create it by hand:  openssl rand -base64 32 | sudo tee $AUTH_SESSION_KEY_FILE"
    print_action "Then:               sudo chmod 600 $AUTH_SESSION_KEY_FILE"
    FAILED+=("missing $AUTH_SESSION_KEY_FILE")
fi

# --- The admin account -------------------------------------------------------
# Stored first and set second, so a password set here is never one nobody
# knows (login-store-decisions.md, decision 6). No vault: asked below instead.
if ! grep -q "^${AUTH_ADMIN_USER}:" "$AUTH_USER_FILE" 2>/dev/null \
   && [ -f "$SCRIPT_DIR/person_entry.sh" ]; then
    ADMIN_PW="$(openssl rand -base64 18)"
    if [ -n "$ADMIN_PW" ] \
       && printf '%s\n' "$ADMIN_PW" | SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/person_entry.sh" --login "$AUTH_ADMIN_USER" 2>/dev/null; then
        if printf '%s\n' "$ADMIN_PW" | SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/manage_auth_users.sh" --add "$AUTH_ADMIN_USER"; then
            print_success "'$AUTH_ADMIN_USER' has a generated password. It is in 1Password, not shown here."
        fi
    fi
    unset ADMIN_PW
fi
# Exit 1 means somebody is still without a password.
if ! bash "$ACCOUNT_SCRIPT" --file "$AUTH_USER_FILE" "$AUTH_ADMIN_USER"; then
    FAILED+=("'$AUTH_ADMIN_USER' has no password")
fi

# --- The failed-login throttle -----------------------------------------------
# Five wrong passwords from one address in ten minutes block that address from
# the web ports for a minute, doubling each time up to a day: slowed, never a
# hard lock anyone on the LAN could trigger against the owner. The LAN is NOT
# exempt here, unlike jail.local's ignoreip, because the LAN is where these
# pages are reached from. SSH is not blocked, so a ban is always undoable:
#   sudo fail2ban-client set login-gate unbanip <address>
JAIL_FILE="/etc/fail2ban/jail.d/login-gate.local"
NEW_JAIL="$(cat <<'EOF'
# Generated by add_login_gate.sh, rewritten on every run.
[login-gate]
enabled  = true
filter   = apache-auth
logpath  = /var/log/apache2/*error.log
port     = 80,443,10000:11999
ignoreip = 127.0.0.1/8 ::1
maxretry = 5
findtime = 10m
bantime  = 1m
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 1d
EOF
)"
if ! command -v fail2ban-client >/dev/null 2>&1; then
    if apt-get install -y -qq fail2ban >/dev/null 2>&1; then
        print_success "Installed fail2ban for the failed-login throttle."
    else
        print_error "Could not install fail2ban, so wrong passwords are not slowed down."
        print_action "Install it by hand: sudo apt-get install -y fail2ban"
        FAILED+=("fail2ban")
    fi
fi
if command -v fail2ban-client >/dev/null 2>&1; then
    if [ -f "$JAIL_FILE" ] && [ "$(cat "$JAIL_FILE")" = "$NEW_JAIL" ]; then
        print_success "Failed-login throttle already in place."
    else
        mkdir -p "$(dirname "$JAIL_FILE")"
        printf '%s\n' "$NEW_JAIL" > "$JAIL_FILE"
        if systemctl enable --now fail2ban >/dev/null 2>&1 && fail2ban-client reload >/dev/null 2>&1; then
            print_success "Failed-login throttle on: 5 tries, then a ban that doubles from 1 minute."
        else
            print_error "fail2ban did not take the throttle."
            print_action "See why: sudo fail2ban-client -t"
            FAILED+=("throttle")
        fi
    fi
fi

# add_app_vhosts.sh reloads once, after its own vhosts: GATE_NO_RELOAD=1.
if [ "$NEEDS_RELOAD" = 1 ] && [ "${GATE_NO_RELOAD:-0}" != 1 ]; then
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2
        print_success "Apache reloaded with the login modules."
    else
        print_error "Apache's config does not pass configtest, so it was not reloaded."
        print_action "See why: sudo apache2ctl configtest"
        FAILED+=("configtest")
    fi
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "The gate is incomplete: ${FAILED[*]}"
    exit 1
fi
print_success "Login gate ready."
