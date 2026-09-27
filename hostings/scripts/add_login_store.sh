#!/usr/bin/env bash
set -e

# =============================================================================
# Keep the login files in the secret store from now on.
# login-store-decisions.md, decision 4.
#
#   sudo bash add_login_store.sh
#
# Installs three units around store_logins.sh:
#   login-store.path     runs it the moment a login file changes, whoever
#                        changed it: the console, htpasswd by hand, doveadm
#   login-store.service  the run itself
#   login-store.timer    hourly, the retry after the vault was unreachable
#
# A unit watching the files, rather than a call in every script that writes
# them, because there are five such scripts and a sixth would be forgotten.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only: every vault call is bounded.
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

LOG="$(mktemp)"
trap 'spinner_stop; rm -f "$LOG"' EXIT

if [ "$EUID" -ne 0 ]; then
    print_error "This installs systemd units, so it needs root."
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
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}

# The pipeline tree, which Jenkins keeps current, when it exists: a unit
# pointing into an installer's clone breaks the day that clone is moved.
PIPELINE_SCRIPT="/usr/local/lib/linuxbasics/hostings/scripts/store_logins.sh"
STORE_SCRIPT="$SCRIPT_DIR/store_logins.sh"
[ -f "$PIPELINE_SCRIPT" ] && STORE_SCRIPT="$PIPELINE_SCRIPT"

UNIT_DIR="/etc/systemd/system"

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()
[ -f "$SITES_CONF" ]   || ERRORS+=("No config at $SITES_CONF. Run this from a clone of the repository.")
[ -f "$STORE_SCRIPT" ] || ERRORS+=("No store_logins.sh at $STORE_SCRIPT.")
command -v op >/dev/null 2>&1 || ERRORS+=("op is not installed. Run first: sudo bash $SCRIPT_DIR/add_1password.sh")
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

print_header "Login files → secret store"

cat > "$UNIT_DIR/login-store.service" <<UNIT
[Unit]
Description=Copy the login files to the secret store
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# A burst of console saves becomes one store: the vault allows 100 writes an hour.
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash $STORE_SCRIPT
UNIT

cat > "$UNIT_DIR/login-store.path" <<UNIT
[Unit]
Description=Watch the login files for changes

[Path]
PathChanged=$(conf_get AUTH_USER_FILE /etc/apache2/.htpasswd-progress)
PathChanged=$(conf_get AUTH_USER_META /etc/apache2/.htpasswd-progress.meta)
PathChanged=/etc/dovecot/users
PathChanged=$(conf_get AUTH_SESSION_KEY_FILE /etc/apache2/session-crypto.key)
PathChanged=$(conf_get DOCKER_BACKUP_PASSWORD_FILE /root/.docker_backup_password)
PathChanged=$(conf_get MAIL_BACKUP_PASSWORD_FILE /root/.mail_backup_password)
PathChanged=$(conf_get GIT_PUSH_KEY "/home/$(conf_get GIT_PUSH_USER nobody)/.ssh/id_ed25519")
Unit=login-store.service

[Install]
WantedBy=multi-user.target
UNIT

cat > "$UNIT_DIR/login-store.timer" <<UNIT
[Unit]
Description=Retry storing the login files hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Unit=login-store.service

[Install]
WantedBy=timers.target
UNIT
print_status "Wrote login-store.service, .path and .timer in $UNIT_DIR, running $STORE_SCRIPT"

systemctl daemon-reload
if ! systemctl enable --now login-store.path login-store.timer > "$LOG" 2>&1; then
    print_error "Could not enable the login-store units:"
    tail -20 "$LOG"
    exit 1
fi
print_status "Enabled login-store.path and login-store.timer"

spinner_start "Storing the login files in the vault..."
FIRST_OK=0
systemctl start login-store.service > "$LOG" 2>&1 && FIRST_OK=1
spinner_stop
if [ "$FIRST_OK" = 1 ]; then
    print_success "First run: $(bash "$STORE_SCRIPT" --status)"
else
    print_error "First run failed: $(bash "$STORE_SCRIPT" --status)"
    print_info "The timer retries hourly. The detail: journalctl -u login-store.service -n 30"
    exit 1
fi
