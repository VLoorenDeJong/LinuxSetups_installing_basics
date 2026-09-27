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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# The hosting manager's audit trail, for its Audit tab.
#
#   read_audit.sh
#
# READ ONLY, and takes no arguments, so the sudoers line for it is exact.
#
# index.php writes one journal line per POST under the tag hosting-manager.
# Only lines logged BY hosting-manager, the page's account, are returned: any
# local account can use that tag with logger, and a line it forged must not
# appear as a console action. Lines from before item 146 were www-data's.
#
# Output is journalctl's JSON, one entry per line, oldest first, at most the
# last 1000 entries of the last 90 days.
# =============================================================================

# No print_* helpers: everything on stdout is JSON for the only caller.

if [ "$EUID" -ne 0 ]; then
    echo '{"error":"must run as root"}'
    exit 1
fi

PAGE_UID="$(id -u hosting-manager 2>/dev/null)" || { echo '{"error":"no hosting-manager account: run add_hosting_manager.sh"}'; exit 1; }

journalctl --no-pager --quiet \
    -t hosting-manager "_UID=${PAGE_UID}" \
    --since "90 days ago" -n 1000 \
    -o json --output-fields=MESSAGE
