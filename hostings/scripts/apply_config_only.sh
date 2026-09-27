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
# Write the vhosts, and nothing else. The fast path for a config-only change.
#
#   apply_config_only.sh          takes no arguments at all
#
# WHY THIS EXISTS. Turning one checkbox on cost about two minutes through
# Jenkins, measured 2026-08-25: 20s of useful work inside 100s of scaffolding
# (queue, workspace fetch, three submodule updates, ten GitHub API reads for
# repositories that did not change, and step overhead). None of that is needed
# to rewrite an Apache vhost.
#
# WHAT IT DOES NOT DO, and this is the whole reason it is safe to press:
#
#   - no repository is created, renamed or pushed to;
#   - no certificate is requested, so no rate limit can be spent;
#   - no systemd unit is written, enabled or restarted;
#   - nothing is pruned, so it cannot delete a thing.
#
# It refreshes the root-owned tree first, because that is the copy the
# generators read. A change that has not been pushed has not taken effect,
# whatever the console shows.
#
# USE THE JENKINS JOB INSTEAD for anything touching repositories, certificates,
# units or a full re-apply. This is the small hammer.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# Yellow means "this needs you", never "warning".
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

if [ "$#" -ne 0 ]; then
    print_error "This script takes no arguments."
    print_action "Run it as: sudo $0"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
PIPELINE_ROOT="/usr/local/lib/linuxbasics"
SCRIPTS="${PIPELINE_ROOT}/hostings/scripts"

# The clone the console publishes from. Its hostings.conf is what the operator
# just pressed a button about, and it is the only thing this script can compare
# against without being told a commit it would have to trust.
. "${SCRIPTS}/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
CONSOLE_CONF="$(conf_active /var/lib/hosting-manager/config-repo/backup_config)"
TREE_CONF="$(conf_active "/etc/hostings")"

print_header "Apply the configuration only"
print_status "Tree:  $PIPELINE_ROOT"
print_info "Vhosts and preview ports. No repository, certificate or unit is touched."

if [ ! -x "${SCRIPTS}/add_pipeline_scripts.sh" ]; then
    print_error "No script tree at ${SCRIPTS}, so there is nothing to run."
    print_action "Install it: sudo bash add_pipeline_scripts.sh"
    exit 1
fi

# The generators read THIS tree's hostings.conf, so it has to hold the commit
# the console just pushed. Without this the run would apply the previous config
# and report success.
# Kept rather than discarded. This is the step everything below depends on, so
# a failure here has to say why on the spot: the log is gone by the time anyone
# thinks to look for it.
REFRESH_LOG="$(mktemp)"
export FPM_RELOAD_DEFER_FILE
FPM_RELOAD_DEFER_FILE="$(mktemp)"
trap 'rm -f "$REFRESH_LOG" "$FPM_RELOAD_DEFER_FILE"' EXIT
bash "${SCRIPTS}/add_pipeline_scripts.sh" >"$REFRESH_LOG" 2>&1 || {
    print_error "Could not refresh $PIPELINE_ROOT, so the config here may be stale."
    tail -n 20 "$REFRESH_LOG" >&2
    print_action "Run the Jenkins apply job instead: it reports why."
    exit 1
}
print_success "Config refreshed to $(git -C "$PIPELINE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)."

# Refreshing is not the same as having refreshed to the right thing. The console
# publishes by pushing to GitHub and this tree refreshes by pulling from it, so
# a pull that runs before the push has propagated brings back the PREVIOUS
# config, writes vhosts for an edit that has already been superseded, and
# reports success.
#
# Measured 2026-08-31: switching a website back on left the vhost serving the
# under-construction page while hostings.conf said the row was enabled. Running
# this script again fixed it with no other change.
#
# Compared as content, because that is the question. The commit is not: the
# console clone and this tree are different clones and can hold the same config
# at different commits.
if [ -r "$CONSOLE_CONF" ] && [ -r "$TREE_CONF" ]; then
    tries=0
    while ! cmp -s "$CONSOLE_CONF" "$TREE_CONF"; do
        tries=$((tries + 1))
        if [ "$tries" -gt 5 ]; then
            print_error "This tree's hostings.conf still does not match the one the console published."
            # Five silent retries and then "it did not match" says nothing about
            # WHY. If the pull was failing rather than the push being slow, the
            # reason is in here.
            tail -n 20 "$REFRESH_LOG" >&2
            print_action "Nothing was written. Run it again in a moment, or use the Jenkins apply job."
            exit 1
        fi
        print_status "Waiting for the push to arrive (attempt ${tries} of 5)..."
        sleep 3
        bash "${SCRIPTS}/add_pipeline_scripts.sh" >"$REFRESH_LOG" 2>&1 || true
    done
    if [ "$tries" -gt 0 ]; then
        print_success "The published config arrived after ${tries} attempt(s)."
    fi
fi

FAILED=0

# Written for the same reason maintain_services.sh writes it, and it HAS to be
# written here too: the console shows the file after any apply, and this path
# does not go through maintain_services.sh at all. Without it, Fix drift left
# the page showing the last JENKINS apply's table as though it were this run's.
# Caught before shipping, 2026-09-03, by asking whether this script writes it.
APPLY_JSON="/var/lib/hosting-manager/last-apply.json"
STEP_JSON=""
record_step() {
    [ -n "$STEP_JSON" ] && STEP_JSON="${STEP_JSON},"
    STEP_JSON="${STEP_JSON}{\"name\":\"$1\",\"state\":\"$2\",\"note\":\"$3\"}"
}

for step in add_app_vhosts.sh add_preview_vhosts.sh; do
    if [ ! -f "${SCRIPTS}/${step}" ]; then
        print_error "${step} is missing from the tree."
        record_step "$step" "failed" "missing from the tree"
        FAILED=1
        continue
    fi
    print_header "$step"
    if ! bash "${SCRIPTS}/${step}"; then
        print_error "${step} failed. The lines above say why."
        record_step "$step" "failed" "exited non-zero"
        FAILED=1
    else
        record_step "$step" "ok" ""
    fi
done

# The two the fast path deliberately does not run, said out loud rather than
# left absent: an operator reading the table should see WHY units and
# certificates did not move, not have to know that this button never touches
# them.
record_step "units and certificates" "skipped" "the fast apply never touches them"
record_step "prune orphans" "skipped" "only the Jenkins apply prunes"

if [ -d /var/lib/hosting-manager ]; then
    _tmp="$(mktemp)"
    printf '{"when":"%s","steps":[%s]}\n' "$(date -Is)" "$STEP_JSON" > "$_tmp"
    install -m 0644 -o root -g root "$_tmp" "$APPLY_JSON" 2>/dev/null || true
    rm -f "$_tmp"
fi

# This script runs inside a console request, and reloading PHP-FPM now would
# kill that request before it answers. Fired after it has.
FPM_UNIT="$(cat "$FPM_RELOAD_DEFER_FILE" 2>/dev/null)"
if [ -n "$FPM_UNIT" ]; then
    if systemd-run --quiet --collect --on-active=5s /usr/bin/systemctl reload "$FPM_UNIT"; then
        print_status "$FPM_UNIT reloads in 5 seconds, once this save has answered."
    else
        print_error "Could not schedule the $FPM_UNIT reload, so new or removed sites are not live yet."
        print_action "Reload it: sudo systemctl reload $FPM_UNIT"
        FAILED=1
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    print_error "Not everything was written. Apache was left as the last good run made it."
    exit 1
fi

print_header "Done"
print_success "Vhosts and preview ports match the published config."
print_info "Units, certificates and repositories were not looked at."
print_action "Use the Jenkins apply job when one of those has to change."
