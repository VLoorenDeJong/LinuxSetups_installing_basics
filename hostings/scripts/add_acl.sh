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
# Installs acl (setfacl, getfacl), which the Shared folders module needs: the
# console's share unlock button opens and closes folders with ACLs, and a
# minimal image ships without them.
#
#   sudo bash add_acl.sh
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

[ "$EUID" -eq 0 ] || { print_error "This needs root: it installs a package."; print_action "sudo bash $0"; exit 2; }

print_header "ACL tools for the shared folders"

if command -v setfacl >/dev/null 2>&1; then
    print_success "acl is already installed."
    exit 0
fi

if apt-get install -y -qq acl >/dev/null 2>&1; then
    print_success "Installed acl."
else
    print_error "Could not install acl, so the share unlock button will refuse."
    print_action "Install it by hand: sudo apt-get install -y acl"
    exit 1
fi
