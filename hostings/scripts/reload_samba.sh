#!/usr/bin/env bash
set -e
# =============================================================================
# Make Samba serve the saved smb.conf, without saving anything.
#
# The REPAIR half of publish_smb.sh: when a save ended "saved, Samba was not
# reloaded", this finishes the job from the console with one button.
#
#   1. CONFIG_SAVE_HOOK pre, so the config directory is up to date
#   2. testparm the file Samba actually reads
#   3. reload, and read back what it serves
# =============================================================================

print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || { print_error "config.sh not found beside $0."; exit 1; }

CONF_DIR="/etc/hostings"
LIVE="$(readlink -f /etc/samba/smb.conf 2>/dev/null || true)"
[ -n "$LIVE" ] || LIVE="/etc/samba/smb.conf"

HOOK="$(sed -n 's/^[[:space:]]*CONFIG_SAVE_HOOK[[:space:]]*=[[:space:]]*//p' "$(conf_active "$CONF_DIR")" 2>/dev/null \
        | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')"
if [ -n "$HOOK" ] && [ "$HOOK" != "-" ]; then
    bash "$HOOK" pre || { print_error "The config directory could not be refreshed, so Samba was NOT reloaded."; exit 1; }
fi

# Reloading a file testparm rejects is how a working Samba is lost, and whoever
# presses this button is usually already looking at something broken.
TP_LOG="$(mktemp)"
if ! testparm -s "$LIVE" >"$TP_LOG" 2>&1; then
    print_error "$LIVE does not pass testparm, so Samba was NOT reloaded."
    tail -n 15 "$TP_LOG"
    rm -f "$TP_LOG"
    exit 1
fi
rm -f "$TP_LOG"
print_success "$LIVE is valid."

# smbcontrol, not a restart: a reload keeps open connections, and one of them
# is usually the person pressing the button.
if ! systemctl is-active --quiet smbd; then
    print_error "smbd is not running, so there was nothing to reload."
    print_info "The config in place is valid and will be read when it starts."
    print_action "  sudo systemctl start smbd"
    exit 1
fi
RELOAD_LOG="$(mktemp)"
if ! smbcontrol all reload-config >"$RELOAD_LOG" 2>&1; then
    print_error "smbcontrol failed, so the new config is not in use."
    tail -n 10 "$RELOAD_LOG"
    rm -f "$RELOAD_LOG"
    exit 1
fi
rm -f "$RELOAD_LOG"

SHARES="$(smbclient -L localhost -N 2>/dev/null | awk '$2 == "Disk" {print $1}' | tr '\n' ' ')"
if [ -z "$SHARES" ]; then
    print_error "Samba reloaded but lists no shares."
    print_info "That is correct if every share is switched off, and a fault otherwise."
    print_action "  sudo testparm -s $LIVE"
    exit 0
fi
print_success "Samba reloaded. It now serves: $SHARES"
