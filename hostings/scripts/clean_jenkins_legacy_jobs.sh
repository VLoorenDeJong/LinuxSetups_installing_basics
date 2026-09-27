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
# Remove the jobs left loose at the top level.
#
# Since the jobs were grouped, the top level holds folders and nothing else. A
# job sitting beside them is left over from an earlier naming round: it points
# at a Jenkinsfile that has been renamed, so it can never run, and it makes the
# list unreadable.
#
# THE RULE, and it is the only one: at the top level, a folder stays and a job
# goes. Nothing inside a folder is ever touched.
#
# A JOB WITH BUILDS IS NEVER DELETED. Build history is the record of what this
# machine actually did, and no tidy-up is worth losing it. Those are reported
# and left, with the command to remove one by hand if that is genuinely wanted.
#
# DRY RUN BY DEFAULT. Nothing is removed until --delete is passed.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[1m=== %s ===\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 [--delete]" >&2
    echo "" >&2
    echo "  (no flag)  list what would be removed, remove nothing. The default." >&2
    echo "  --delete   actually remove the empty leftover jobs." >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  JENKINS_HOME  override where Jenkins keeps its jobs" >&2
    exit 1
}

DELETE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --delete)  DELETE=1; shift ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JOBS_DIR="$JENKINS_HOME/jobs"

if [ "$DELETE" -eq 1 ] && [ "$EUID" -ne 0 ]; then
    print_error "Removing jobs needs sudo."
    print_action "See what it would do first: $0"
    exit 1
fi

[ -d "$JOBS_DIR" ] || { print_error "No jobs directory at $JOBS_DIR."; exit 1; }

print_header "Loose jobs at the top level"
print_status "Jenkins: $JENKINS_HOME"
[ "$DELETE" -eq 0 ] && print_info "Listing only. Nothing will be removed."

EMPTY=()
WITH_BUILDS=()
FOLDERS=0

for d in "$JOBS_DIR"/*/; do
    [ -f "$d/config.xml" ] || continue
    name="$(basename "$d")"

    # A folder is the whole point of the layout. Never touched, and neither is
    # anything inside one.
    if grep -q "cloudbees.hudson.plugins.folder.Folder" "$d/config.xml" 2>/dev/null; then
        FOLDERS=$(( FOLDERS + 1 ))
        continue
    fi

    builds=0
    if [ -d "$d/builds" ]; then
        builds="$(find "$d/builds" -maxdepth 1 -type d -regex '.*/[0-9]+' 2>/dev/null | wc -l | tr -d ' ')"
    fi

    if [ "$builds" -gt 0 ]; then
        WITH_BUILDS+=("$name ($builds build(s))")
    else
        EMPTY+=("$name")
    fi
done

echo ""
print_status "$FOLDERS folder(s), left alone."

if [ ${#EMPTY[@]} -eq 0 ] && [ ${#WITH_BUILDS[@]} -eq 0 ]; then
    print_success "Nothing loose at the top level. The layout is already clean."
    exit 0
fi

if [ ${#EMPTY[@]} -gt 0 ]; then
    echo ""
    print_status "${#EMPTY[@]} leftover job(s) with no builds:"
    for n in "${EMPTY[@]}"; do print_status "  - $n"; done
fi

if [ ${#WITH_BUILDS[@]} -gt 0 ]; then
    echo ""
    print_info "${#WITH_BUILDS[@]} leftover job(s) that HAVE run, and are kept:"
    for n in "${WITH_BUILDS[@]}"; do print_info "  - $n"; done
    print_info "History is the record of what this machine did, so these are never"
    print_action "removed automatically. To drop one deliberately, name it:"
    print_action "  sudo rm -rf $JOBS_DIR/<name>   then restart Jenkins"
fi

if [ "$DELETE" -eq 0 ]; then
    echo ""
    print_status "Nothing was removed. To remove the ${#EMPTY[@]} empty one(s):"
    print_status "  sudo $0 --delete"
    exit 0
fi

if [ ${#EMPTY[@]} -eq 0 ]; then
    print_success "Nothing to remove."
    exit 0
fi

echo ""
print_header "Removing"
for n in "${EMPTY[@]}"; do
    rm -rf "${JOBS_DIR:?}/${n:?}"
    print_success "Removed $n"
done

if systemctl is-active --quiet jenkins 2>/dev/null; then
    print_status "Restarting Jenkins so the list matches..."
    systemctl restart jenkins || print_action "Jenkins did not restart. Do it by hand."
    print_success "Jenkins restarted."
else
    print_info "Jenkins is not running, so the change shows when it next starts."
fi
