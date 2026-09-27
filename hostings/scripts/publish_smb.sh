#!/usr/bin/env bash
set -e

# =============================================================================
# Authenticating git to GitHub goes through ONE file
#
# git_credential_github_app.sh reads the repository OWNER out of the URL git
# hands it and mints that installation's token. This script used to carry its
# own helper with a single owner-blind token, which is correct only while every
# repository has the same owner. Measured 2026-09-12: an org token gets
# "remote: Repository not found." for a personal-account repository, a 404 that
# names no cause.
#
# credential.useHttpPath is what makes the choice possible: without it git tells
# the helper the host only, and every github.com URL looks identical.
#
# THE INLINE FALLBACK STAYS, and it is deliberate. project-context.md principle
# 2b: one file talks to an outside service, and a caller MAY keep its own copy
# so a lone script on a bare machine still runs. This is that copy, and it is
# only ever the read path.
#
# "!bash <path>" rather than the path alone: the pipeline tree chmods every file
# in it to 644, so a helper named by path is not executable there.
# =============================================================================
# Through repo_host.sh: repo_git is git with the forge's credential helper
# already configured. This file resolved the helper itself and built the -c
# flags itself, which is the same three lines publish_hostings.sh had.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# shellcheck source=/dev/null
. "$(_iface repo_host.sh)"

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
# Take an edited smb.conf, check it, commit it, push it, reload Samba.
#
# The same shape as publish_hostings.sh, and for the same reason: the page runs
# as hosting-manager, holds no credential, writes a candidate to a fixed path and calls
# this through sudo with no arguments. sudo matches a literal command, so a rule
# ending in a wildcard would let the caller choose the rest of the argument
# list. There is nothing here to smuggle in.
#
# WHY THIS ONE ALSO RELOADS
#
# hostings.conf describes units, vhosts and certificates, so applying it is a
# separate act with a drift report in front of it. smb.conf IS the running
# config: /etc/samba/smb.conf is a symlink into a clone of this repository. There is
# nothing to render and nothing to drift, so publishing and reloading are one
# act.
#
# WHAT IT REFUSES
#
# testparm is run twice: once on the candidate before it is committed, and once
# on the file Samba will actually read after that clone is updated. A malformed
# share does not break that share, it stops smbd, and the folder shares are how
# this machine is reached.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# An unindented continuation of the line above it, so a two-line point reads as
# one. Every other script in this fleet that calls it defines it; this one
# called it and did not, so the run ended with `print_hint: command not found`.
print_hint()    { printf "   %s\n" "$1"; }
# Yellow means "this needs you", never "warning".
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
STAGING="${MANAGER_HOME}/smb.conf.candidate"
BASE_HASH_FILE="${MANAGER_HOME}/smb.candidate.base"
CLONE="${MANAGER_HOME}/config-repo"
TRACKED="/etc/hostings/smb/smb.conf"
# The file Samba actually reads. /etc/samba/smb.conf is a symlink into a clone
# of this repository, and that symlink is the declaration of which clone is
# authoritative: this script pulls whatever it resolves into rather than
# hardcoding a path, so moving the link moves the publish with it.
SMB_LINK="/etc/samba/smb.conf"
REPORT="${MANAGER_HOME}/last-smb-check.txt"
LOCK="/var/lock/publish_smb.lock"

# =============================================================================
# THE APP PUSHES. THE SSH KEY IS FOR THE FIRST CLONE ONLY.
#
# Decided 2026-09-06, item 89. Same helper as publish_hostings.sh,
# carried here rather than sourced: every script in this fleet holds its own
# copy of the shared helpers so it stays individually runnable.
#
# The token is minted at the point of use and never stored. It lives one hour.
# It reaches git through a credential helper and through the ENVIRONMENT, never
# the argument list: anything here can read /proc/<pid>/cmdline while git runs.
# =============================================================================
GH_TOKEN=""
mint_token() {
    local sh
    for sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh \
              "${CLONE}/hostings/scripts/github_app_token.sh"; do
        [ -f "$sh" ] || continue
        GH_TOKEN="$(SITES_CONF= \
            bash "$sh" 2>/dev/null || true)"
        [ -n "$GH_TOKEN" ] && { export GH_TOKEN; return 0; }
    done
    return 1
}

git_app() { repo_git "$@"; }

# An SSH remote cannot carry a token, so the URL is given to git per command
# rather than rewritten into .git/config. A machine whose remote is still git@
# keeps working either way.
HTTPS_REMOTE=""
resolve_https_remote() {
    local u
    u="$(git -C "$CLONE" remote get-url origin 2>/dev/null || true)"
    HTTPS_REMOTE="$(repo_https_url "$u" 2>/dev/null || true)"
    [ -n "$HTTPS_REMOTE" ]
}

print_header "Publish smb.conf"

# One at a time. Two publishes racing means two commits built from two different
# starting points, and whichever loses is silently discarded.
exec 9>"$LOCK"
if ! flock -n 9; then
    print_error "Another publish is already running. Try again in a moment."
    exit 1
fi

# Emptied, never deleted: /var/lib/hosting-manager is 0755 root, so the page can
# write these files but cannot create them. Removing one turns every save after
# the first into "Could not write ...".
clear_staging() {
    for f in "$@"; do
        install -m 600 -o hosting-manager -g hosting-manager /dev/null "$f" 2>/dev/null || rm -f "$f"
    done
}

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()

[ -f "$STAGING" ]      || ERRORS+=("Nothing to publish: $STAGING does not exist")
[ -d "$CLONE/.git" ]   || ERRORS+=("No clone at $CLONE. Run add_hosting_manager.sh first.")
# The App only: the SSH key is for the first clone of a machine, the owner
# 2026-09-13. Checked by minting, because item 74 records a present key with a
# revoked installation looking identical on disk.
if ! mint_token; then
    ERRORS+=("No GitHub App token could be minted. Check it: sudo provision_repo.sh --check")
fi
command -v testparm >/dev/null 2>&1 \
    || ERRORS+=("testparm is not installed, so nothing can be validated. Install samba-common-bin.")

# Checked here, not discovered after the commit is pushed and the clone moved.
for t in smbcontrol smbclient runuser; do
    command -v "$t" >/dev/null 2>&1 \
        || ERRORS+=("$t is not installed, so the change could not be made live.")
done

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Cannot publish. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

if [ ! -s "$STAGING" ]; then
    print_error "The candidate file is empty, which would remove every share."
    exit 1
fi

# =============================================================================
# Start from the branch, and refuse a candidate built on a file that has moved
# =============================================================================
cd "$CLONE"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
print_status "Clone:  $CLONE"
print_status "Branch: $BRANCH"

if ! resolve_https_remote; then
    print_error "The clone's origin is not a URL the forge understands. Nothing was published."
    exit 1
fi
print_status "Auth:   the GitHub App, over HTTPS"

# FETCH_HEAD and not origin/<branch>: `git fetch <url>` leaves origin/<branch>
# alone, so resetting to it would restore the stale commit.
if ! git_app fetch --quiet "$HTTPS_REMOTE" "$BRANCH"; then
    print_error "Could not reach GitHub as the App. Nothing was published."
    print_action "Check the App: sudo provision_repo.sh --check"
    exit 1
fi
git reset --quiet --hard FETCH_HEAD

# The page sends the hash of the file it was shown. A missing hash is a refusal,
# not a pass: on hostings.conf that exact `if [ -f ]` mistake meant the guard had
# never once run, and a save reverted a day of work.
# Line one is the hash the page was shown, line two who pressed Save.
SEEN="$(sed -n 1p "$BASE_HASH_FILE" 2>/dev/null || true)"
SAVED_BY="$(sed -n 2p "$BASE_HASH_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._@-' | cut -c1-64 || true)"
SAVED_BY="${SAVED_BY:-unknown}"
NOW="$(git hash-object "$TRACKED")"

if [ -z "$SEEN" ]; then
    print_error "The page did not say which version it was editing, so nothing was published."
    print_info "That file is ${BASE_HASH_FILE}, and it must be writable by hosting-manager, the page's account:"
    print_action "  sudo install -m 600 -o hosting-manager -g hosting-manager /dev/null ${BASE_HASH_FILE}"
    print_info "Nothing was lost: the version on the branch is untouched."
    clear_staging "$STAGING"
    exit 1
fi

if [ "$SEEN" != "$NOW" ]; then
    print_error "smb.conf changed while the page was open, so nothing was published."
    print_action "Reload the hosting manager and make the edit again."
    print_info "Nothing was lost: the version on the branch is untouched."
    clear_staging "$STAGING" "$BASE_HASH_FILE"
    exit 1
fi

cp "$STAGING" "$TRACKED"

if git diff --quiet -- "$TRACKED"; then
    print_success "No change: smb.conf already matches what was submitted."
    clear_staging "$STAGING"
    exit 0
fi

# =============================================================================
# Validate it as a Samba config before it becomes a commit
#
# testparm's EXIT CODE IS NOT A VALIDATION. Measured on this machine
# 2026-08-26: a share with no path and an invented parameter returns 0, both
# with and without --parameter-name. What it does do is say so on stdout, so
# the output is what has to be read.
# =============================================================================
check_with_testparm() {
    local file="$1" what="$2" log rc faults
    log="$(mktemp)"
    set +e
    # No --parameter-name: that makes testparm print one value and skip the
    # global and per-service checks this is here for.
    testparm --suppress-prompt "$file" >"$log" 2>&1
    rc=$?
    set -e

    # The wordings testparm uses for the two faults a share edit can introduce,
    # plus its own hard errors. Anchored to its real output, not guessed.
    faults="$(grep -iE 'Unknown parameter|No path in service|^ERROR|Rejecting|Invalid' "$log" || true)"

    {
        echo "Checked $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Command: testparm --suppress-prompt, on $what"
        echo "Result:  $([ "$rc" -eq 0 ] && [ -z "$faults" ] && echo "smb.conf is valid" || echo "FAILED")"
        echo ""
        cat "$log"
    } > "${REPORT}.tmp"
    install -m 0644 -o root -g root "${REPORT}.tmp" "$REPORT"
    rm -f "${REPORT}.tmp"

    if [ "$rc" -ne 0 ] || [ -n "$faults" ]; then
        print_error "smb.conf is not valid, so it was NOT published."
        print_info "Nothing on the machine changed. What testparm said:"
        if [ -n "$faults" ]; then
            printf '%s\n' "$faults" | head -n 20
        else
            tail -n 20 "$log"
        fi
        print_info "The whole check is in $REPORT"
        rm -f "$log"
        return 1
    fi
    rm -f "$log"
    return 0
}

print_status "Validating the new smb.conf..."
if ! check_with_testparm "$TRACKED" "the config being published"; then
    git checkout --quiet -- "$TRACKED"
    exit 1
fi
print_success "smb.conf is valid."

# =============================================================================
# Commit and push
# =============================================================================
git -c user.name="${SAVED_BY} via the hosting manager" \
    -c user.email="hosting-manager@localhost" \
    commit --quiet -m "Edit smb.conf from the hosting manager

Saved by: ${SAVED_BY}

Published by publish_smb.sh on $(hostname), validated by testparm before
this commit was made." \
    -- "$TRACKED"

PUSH_LOG="$(mktemp)"
_pushed=0
git_app push "$HTTPS_REMOTE" "HEAD:$BRANCH" >"$PUSH_LOG" 2>&1 && _pushed=1
if [ "$_pushed" -ne 1 ]; then
    print_error "Could not push, so nothing was made live."
    tail -n 10 "$PUSH_LOG"
    # Not "the same commit": the next run hard-resets to origin, so the commit
    # is rebuilt from the candidate rather than re-pushed.
    print_action "Fix the cause, then save again: it will rebuild and push the change."
    rm -f "$PUSH_LOG"
    exit 1
fi
rm -f "$PUSH_LOG"

print_success "Pushed to origin/$BRANCH"
clear_staging "$STAGING" "$BASE_HASH_FILE"


# =============================================================================
# Make it live
#
# /etc/samba/smb.conf is a symlink into a clone, so bringing that clone up to
# date IS the deploy. Nothing is rendered and nothing is copied.
#
# The clone is whatever the symlink resolves into, which is the deploy account's
# own working clone: the file it edits by hand is the file Samba reads, and that
# is the point of pointing the link there.
#
# THE ORDER MATTERS. The fast-forward replaces the file Samba reads, so the
# config is validated BEFORE the clone is moved, never after. A check that runs
# afterwards can only report a machine that is already wrong.
# =============================================================================
LIVE="$(readlink -f "$SMB_LINK" 2>/dev/null || true)"

if [ -z "$LIVE" ] || [ ! -f "$LIVE" ]; then
    print_error "$SMB_LINK does not resolve to a file, so Samba was not reloaded."
    print_action "Run add_hosting_manager.sh on the machine to point it at a clone."
    print_info "The change is pushed. Samba still serves the previous config."
    exit 1
fi

# safe.directory for this one read, because git run by root refuses a repo
# owned by somebody else UNLESS SUDO_UID says root got there from that owner.
# The page is hosting-manager, so it never does: measured 2026-08-26, the same command
# succeeds from the owner's shell and fails from the page with "dubious ownership".
# Every git call after this one runs as the clone's owner, which needs no
# exception at all.
LIVE_CLONE="$(git -C "$(dirname "$LIVE")" -c safe.directory='*' rev-parse --show-toplevel 2>/dev/null || true)"

if [ -z "$LIVE_CLONE" ]; then
    print_error "$LIVE is not inside a git clone, so it cannot be brought up to date."
    print_info "The change is pushed. Samba still serves the previous config."
    exit 1
fi

# %U prints UNKNOWN for an unmapped uid, and running as UNKNOWN fails later with
# a message about git rather than about the owner.
CLONE_OWNER="$(stat -c %U "$LIVE_CLONE")"
if [ "$CLONE_OWNER" = "UNKNOWN" ] || ! id -u "$CLONE_OWNER" >/dev/null 2>&1; then
    print_error "$LIVE_CLONE is owned by a uid with no account, so it was not updated."
    print_info "The change is pushed. Samba still serves the previous config."
    exit 1
fi

# The clone may sit on a different branch than the one just published to. A
# fast-forward would then move somebody's branch onto another branch's tip.
LIVE_BRANCH="$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [ "$LIVE_BRANCH" != "$BRANCH" ]; then
    print_error "$LIVE_CLONE is on '$LIVE_BRANCH', not '$BRANCH', so it was not updated."
    print_action "  cd $LIVE_CLONE && git checkout $BRANCH"
    print_info "The change is pushed. Samba still serves the previous config."
    exit 1
fi

# =============================================================================
# Prove the incoming commit is a valid Samba config BEFORE it lands
#
# git show, not the working tree: the file on disk is still the old one, and it
# has to stay that way until this passes.
# =============================================================================
print_status "Checking the published config before it is made live..."
INCOMING="$(mktemp)"
if ! git -C "$CLONE" show "HEAD:$TRACKED" > "$INCOMING" 2>/dev/null; then
    print_error "Could not read the published smb.conf back, so nothing was made live."
    rm -f "$INCOMING"
    exit 1
fi

if ! check_with_testparm "$INCOMING" "the published config, before it is made live"; then
    print_error "The published smb.conf does not pass testparm, so $LIVE_CLONE was NOT moved."
    print_info "Samba still serves the previous config, and the file on disk is still the old one."
    print_action "Undo the commit: cd $CLONE && sudo git revert --no-edit HEAD && sudo git push"
    rm -f "$INCOMING"
    exit 1
fi
rm -f "$INCOMING"

# =============================================================================
# Move the clone
#
# As its owner, WITH THE APP TOKEN. This fetch carried no credential at
# all, so on a machine whose remote is HTTPS it failed with
#
#   fatal: could not read Username for 'https://github.com'
#
# and every SMB save since the move to HTTPS reported "Could not fast-forward"
# with the push already done: the change was published and Samba kept serving
# the old file. Measured 2026-09-09. The push above has authenticated as the
# App since item 89; this step was missed because it is a FETCH.
#
# The token goes through the environment and a credential helper, never the
# argument list, and runuser drops the environment unless it is told not to.
# =============================================================================
print_status "Updating $LIVE_CLONE as $CLONE_OWNER..."
FF_LOG="$(mktemp)"

ff_git() {
    runuser -u "$CLONE_OWNER" --preserve-environment -- \
        git -C "$LIVE_CLONE" \
        -c credential.helper= \
        -c credential.helper="$REPO_GIT_CRED" -c credential.useHttpPath=true \
        "$@"
}

# The HTTPS form of the live clone's own remote, so a git@ origin is never
# fetched over SSH with the owner's key.
LIVE_REMOTE="$(repo_https_url "$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)"

if [ -z "$LIVE_REMOTE" ] \
   || ! ff_git fetch "$LIVE_REMOTE" "$BRANCH" >"$FF_LOG" 2>&1 \
   || ! ff_git merge --ff-only FETCH_HEAD >>"$FF_LOG" 2>&1; then
    print_error "Could not fast-forward $LIVE_CLONE, so Samba was not reloaded."
    tail -n 10 "$FF_LOG"
    # What is actually in the way, rather than a guess at it. On 2026-08-26 this
    # was a submodule pointer left modified by a pull elsewhere, and the guessed
    # message sent the reader looking at smb.conf, which was clean.
    DIRTY="$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" status --porcelain 2>/dev/null | head -n 10)"
    if [ -n "$DIRTY" ]; then
        print_info "That clone has uncommitted changes, and git will not move over them:"
        printf '%s\n' "$DIRTY"
        case "$DIRTY" in
            *LinuxBasics*|*.claude/*|*example-org*)
                print_action "  cd $LIVE_CLONE && git submodule update --init --recursive"
                ;;
        esac
    else
        print_info "The App token may not reach that clone's remote, or the clone has"
        print_info "its own commits."
    fi
    print_action "  cd $LIVE_CLONE && git status"
    print_info "The change is pushed. Samba still serves the previous config."
    rm -f "$FF_LOG"
    exit 1
fi
rm -f "$FF_LOG"

# The file Samba reads is now the published one, or the fast-forward did not do
# what it said. Comparing content is a different claim from re-validating it.
if [ "$(git -C "$CLONE" rev-parse "HEAD:$TRACKED")" != "$(runuser -u "$CLONE_OWNER" -- git -C "$LIVE_CLONE" hash-object "$LIVE")" ]; then
    print_error "$LIVE does not match what was published, so Samba was NOT reloaded."
    print_action "  cd $LIVE_CLONE && git status"
    exit 1
fi

print_success "$LIVE is now the published config."

# =============================================================================
# Reload
#
# smbcontrol, not systemctl restart: a reload keeps every open connection, and
# one of those is usually the person making the change. It broadcasts, so it
# returns 0 with nothing listening: smbd is checked before, and the shares are
# read back after.
# =============================================================================
if ! systemctl is-active --quiet smbd; then
    print_error "smbd is not running, so there was nothing to reload."
    print_info "The published config is in place and will be read when it starts."
    print_action "  sudo systemctl status smbd"
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

# Asking Samba what it serves, rather than trusting a broadcast that cannot fail.
SHARES="$(smbclient -L localhost -N 2>/dev/null | awk '$2 == "Disk" {print $1}' | tr '\n' ' ')"
if [ -z "$SHARES" ]; then
    print_error "Samba reloaded but lists no shares, which is not what was published."
    print_action "  sudo systemctl status smbd && sudo testparm $LIVE"
    exit 1
fi

print_success "Samba reloaded. It now serves: $SHARES"

# Serving shares and being findable are two different things: Windows browses
# with WS-Discovery, which Samba does not speak, so a machine can serve
# perfectly and still be absent from Explorer's Network pane. add_wsdd.sh
# answers those probes; it is idempotent, so running it on every publish is
# free after the first time.
#
# It lives in LinuxBasics beside add_smb.sh, because it is the same job and one
# copy serves every branch. The local path is tried first so a machine running
# an older tree still finds it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSDD=""
for candidate in "$HERE/add_wsdd.sh" "$HERE/../../install_scripts/add_wsdd.sh"; do
    [ -x "$candidate" ] || continue
    WSDD="$candidate"
    break
done

if [ -n "$WSDD" ]; then
    "$WSDD" || print_action "Discovery setup failed. Shares still work: sudo $WSDD --status"
else
    print_info "add_wsdd.sh is not beside this script, so discovery was not set up."
    print_hint "without it the shares work but the machine is invisible under Network."
fi
