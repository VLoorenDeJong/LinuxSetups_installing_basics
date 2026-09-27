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
# already configured, and repo_https_url turns an SSH remote into the URL a
# token can be used with. This file used to resolve the helper itself, build
# the -c flags itself, and name github.com in a sed.
#
# NOT optional. Every console save comes through here, and a push that quietly
# used the wrong credential is worse than one that refuses: the operator sees
# success and the config is not where they think it is.
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
# Take an edited hostings.conf, check it, commit it, push it, build it.
#
# This is the privileged half of the hosting manager. The page runs as hosting-manager,
# the most internet-exposed process on the machine, and holds no credential at
# all: it writes a candidate file to a staging path and calls this script
# through sudo with no arguments.
#
# WHY NO ARGUMENTS
#
# sudo matches a literal command. A rule ending in a wildcard lets the caller
# control the rest of the argument list, so this takes its input from a fixed
# path instead. There is nothing to smuggle in.
#
# WHAT IT REFUSES
#
# The candidate is validated by maintain_services.sh --check before it is
# committed. A config that would break the machine never reaches the branch
# Jenkins builds from, so a typo in a browser cannot take the sites down.
#
# The old file is kept. A bad config that passes validation is one `git revert`
# away, and the file it replaced is on disk until the next run.
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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
STAGING="/var/lib/hosting-manager/hostings.conf.candidate"
MANAGER_HOME="/var/lib/hosting-manager"
CLONE="${MANAGER_HOME}/config-repo"
. "$CLONE/hostings/scripts/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
# =============================================================================
# THE APP PUSHES. THE SSH KEY IS FOR THE FIRST CLONE ONLY.
#
# Decided 2026-09-06, item 89. Every hostings change, every SMB
# publish and every create write-back authenticates as the GitHub App over
# HTTPS; the account key at GIT_PUSH_KEY is left with one job, which is the
# first clone on a fresh machine.
#
# Why the key could not simply go: the config repository is private and
# github_app_token.sh lives INSIDE it, so nothing can mint a token to fetch the
# repository that holds the minter. That is a genuine chicken and egg and it is
# bootstrap only. Item 74 also kept the key for pushing to newly created
# repositories, and that reason was measured wrong on 2026-09-06: an App token
# clones the config repository and answers `Everything up-to-date` to a real push.
#
# What the App buys over the key: it is scoped to the installation rather than
# to everything the account owns, and it expires in an hour, so a leaked token
# is worth almost nothing. The key is write access to every repository the
# account can reach, with no expiry.
#
# THE TOKEN IS MINTED AT THE POINT OF USE AND NEVER STORED. It lives one hour,
# so caching it buys nothing and writing it anywhere is the exposure the App
# exists to avoid.
# =============================================================================
GH_TOKEN=""
mint_token() {
    local sh
    for sh in /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh \
              "${CLONE}/hostings/scripts/github_app_token.sh"; do
        [ -f "$sh" ] || continue
        GH_TOKEN="$(SITES_CONF="$(conf_active "$(dirname "$(dirname "$(dirname "$sh")")")/backup_config")" \
            bash "$sh" 2>/dev/null || true)"
        [ -n "$GH_TOKEN" ] && { export GH_TOKEN; return 0; }
    done
    return 1
}

# The token reaches git through a credential helper, and through the
# ENVIRONMENT rather than the argument list: anything on this machine can read
# /proc/<pid>/cmdline while git runs. The helper text names the variable; the
# value is never in argv.
git_app() { repo_git "$@"; }

# An SSH remote cannot carry a token, so the URL is given to git per command
# rather than rewritten into .git/config. Nothing about the clone changes, and a
# machine whose remote is still git@ keeps working.
HTTPS_REMOTE=""
resolve_https_remote() {
    local u
    u="$(git -C "$CLONE" remote get-url origin 2>/dev/null || true)"
    HTTPS_REMOTE="$(repo_https_url "$u" 2>/dev/null || true)"
    [ -n "$HTTPS_REMOTE" ]
}

REPORT="${MANAGER_HOME}/last-check.txt"
LOCK="/var/lock/publish_hostings.lock"

# --refresh: bring the clone up to the branch and stop. No candidate, no commit,
# no push.
#
# The page is BUILT from this clone, so a change pushed from anywhere else was
# invisible until somebody happened to save in the browser: the operator then
# edited a stale file and the stale-edit guard refused the save. Publishing
# already starts with this same fetch and reset; this exposes it on its own so
# the apply can keep the clone current.
#
# It is the one argument this script takes, and it is a literal in sudoers for
# the same reason the no-argument form is: nothing about it comes from the
# caller.
REFRESH_ONLY=0
if [ "${1:-}" = "--refresh" ]; then REFRESH_ONLY=1; shift; fi

# --go-live: fill hostings.conf from hostings.test.conf (conf_golive), check it,
# commit and push. Called by go_live.sh as root; the page never passes it.
GO_LIVE=0
if [ "${1:-}" = "--go-live" ]; then GO_LIVE=1; shift; fi

if [ "$GO_LIVE" -eq 1 ]; then
    print_header "Go live: fill hostings.conf from the test file"
    exec 9>"$LOCK"
    flock -n 9 || { print_error "A publish is already running. Try again in a moment."; exit 1; }
    [ -d "$CLONE/.git" ] || { print_error "No clone at $CLONE. Run add_hosting_manager.sh first."; exit 1; }
    cd "$CLONE"
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    if ! mint_token || ! resolve_https_remote \
       || ! git_app fetch --quiet "$HTTPS_REMOTE" "$BRANCH"; then
        print_error "Could not reach GitHub as the App. Nothing was changed."
        print_action "Check the App: sudo provision_repo.sh --check"
        exit 1
    fi
    git reset --quiet --hard FETCH_HEAD
    . "$CLONE/hostings/scripts/config.sh" || { print_error "No config.sh in $CLONE."; exit 1; }

    if ! NEW="$(conf_golive "$CLONE/backup_config")"; then
        print_error "Refused: hostings.conf already holds a live config, or there is no test file."
        print_info "Go live never overwrites a live config. Nothing was changed."
        exit 1
    fi
    printf '%s\n' "$NEW" > /etc/hostings/hostings.conf

    print_status "Validating the live config..."
    if ! SITES_CONF="$CLONE/backup_config/hostings.conf" \
         bash hostings/scripts/maintain_services.sh --check >/tmp/golive-publish.log 2>&1; then
        print_error "The live config is not valid, so it was NOT published:"
        sed 's/\x1b\[[0-9;]*m//g' /tmp/golive-publish.log | grep -E '^❌' | head -n 20
        git checkout --quiet -- /etc/hostings/hostings.conf
        exit 1
    fi

    git -c user.name="go_live.sh via the hosting manager" \
        -c user.email="hosting-manager@localhost" \
        commit --quiet -m "Go live: hostings.conf from hostings.test.conf

Published by publish_hostings.sh --go-live on $(hostname). The live
vault keys kept their values; MACHINE_IS_LIVE = yes." \
        -- /etc/hostings/hostings.conf
    if ! git_app push --quiet "$HTTPS_REMOTE" "HEAD:$BRANCH"; then
        git reset --quiet --hard HEAD^
        print_error "Could not push, so nothing went live. Run it again."
        exit 1
    fi
    print_success "hostings.conf is the live config now, pushed as $(git rev-parse --short HEAD)."
    exit 0
fi

if [ "$REFRESH_ONLY" -eq 1 ]; then
    print_header "Refresh the console clone"
    if [ ! -d "$CLONE/.git" ]; then
        print_error "No clone at $CLONE. Run add_hosting_manager.sh first."
        exit 1
    fi
    cd "$CLONE"
    BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    BEFORE="$(git rev-parse --short HEAD)"

    # THE APP ONLY. The key is for the first clone of a machine, the owner
    # 2026-09-13, so a machine that cannot mint says so instead of falling back.
    if ! mint_token || ! resolve_https_remote; then
        print_error "No GitHub App token could be minted. The clone is unchanged at ${BEFORE}."
        print_action "Check the App: sudo provision_repo.sh --check"
        exit 1
    fi
    print_status "Fetching as the GitHub App."
    if ! git_app fetch --quiet "$HTTPS_REMOTE" "$BRANCH"; then
        print_error "Could not reach GitHub as the App. The clone is unchanged at ${BEFORE}."
        print_action "Check the App: sudo provision_repo.sh --check"
        exit 1
    fi
    git reset --quiet --hard FETCH_HEAD
    AFTER="$(git rev-parse --short HEAD)"
    if [ "$BEFORE" = "$AFTER" ]; then
        print_success "Console clone already at ${AFTER}."
    else
        print_success "Console clone ${BEFORE} -> ${AFTER}."
    fi
    exit 0
fi

print_header "Publish hostings.conf"

# One at a time. Two publishes racing means two commits built from two different
# starting points, and whichever loses is silently discarded.
exec 9>"$LOCK"
if ! flock -n 9; then
    print_error "Another publish is already running. Try again in a moment."
    exit 1
fi

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()

[ -f "$STAGING" ] || ERRORS+=("Nothing to publish: $STAGING does not exist")
[ -d "$CLONE/.git" ] || ERRORS+=("No clone at $CLONE. Run add_hosting_manager.sh first.")
# Checked by minting, not by a file test: item 74 records a present key with a
# revoked installation looking identical on disk.
if ! mint_token; then
    ERRORS+=("No GitHub App token could be minted. Check it: sudo provision_repo.sh --check")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Cannot publish. Nothing was changed."
    for e in "${ERRORS[@]}"; do print_error "  - $e"; done
    exit 1
fi

if [ ! -s "$STAGING" ]; then
    print_error "The candidate file is empty, which would delete every site."
    exit 1
fi

# =============================================================================
# Validate it as a config before it becomes a commit
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

# Start from what is on the branch, so a change made in VS Code five minutes ago
# is not silently reverted by a page that loaded before it.
#
# FETCH_HEAD and not origin/<branch>: `git fetch <url>` leaves origin/<branch>
# where it was, so resetting to it would silently restore the stale commit.
if ! git_app fetch --quiet "$HTTPS_REMOTE" "$BRANCH"; then
    print_error "Could not reach GitHub as the App. Nothing was published."
    print_action "Check the App: sudo provision_repo.sh --check"
    exit 1
fi
git reset --quiet --hard FETCH_HEAD

# The file in force after the fetch: MACHINE_IS_LIVE may have just changed.
CONF_REL="/etc/hostings/$(basename "$(conf_active "$CLONE/backup_config")")"
print_status "File:   $CONF_REL"

# REFUSE A CANDIDATE BUILT ON A FILE THAT HAS SINCE MOVED.
#
# The page loads the config, the operator edits part of it, and the whole file
# comes back on save. If anything changed on the branch in between, writing that
# file deletes the change without mentioning it. That is not theoretical: on
# 2026-08-09 a save silently removed the console's port and its comments, because
# the clone was behind and the page had never seen them.
#
# The page sends the hash of what it was shown. If the file has moved since,
# nothing is written and the operator reloads.
# A MISSING HASH IS A REFUSAL, NOT A PASS.
#
# This used to be `if [ -f ... ]`, so no file meant no check. The file was never
# created by the installer and the directory is 0755 root, so the page could not
# create it either: the guard had never once run. On 2026-08-10 a save from the
# page reverted a day of work, including a field every script had learned to
# read, and --check passed it because the stale clone matched the stale format.
BASE_HASH_FILE="${MANAGER_HOME}/candidate.base"

# Emptied, never deleted. This directory is 0755 root, so the page can write
# these two files but cannot CREATE them: removing one turns every save after
# the first into "Could not write ...", which is what the page reported on
# 2026-08-11. Truncating leaves the file for the page to write into and still
# means "nothing staged" to everything that reads it.
clear_staging() {
    for f in "$@"; do
        install -m 600 -o hosting-manager -g hosting-manager /dev/null "$f" 2>/dev/null || rm -f "$f"
    done
}
# Line one is the hash the page was shown, line two who pressed Save.
SEEN="$(sed -n 1p "$BASE_HASH_FILE" 2>/dev/null || true)"
SAVED_BY="$(sed -n 2p "$BASE_HASH_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._@-' | cut -c1-64 || true)"
SAVED_BY="${SAVED_BY:-unknown}"
NOW="$(git hash-object "$CONF_REL")"

if [ -z "$SEEN" ]; then
    print_error "The page did not say which version it was editing, so nothing was published."
    print_info "That file is ${BASE_HASH_FILE}, and it must be writable by hosting-manager, the page's account:"
    print_action "  sudo install -m 600 -o hosting-manager -g hosting-manager /dev/null ${BASE_HASH_FILE}"
    print_info "Nothing was lost: the version on the branch is untouched."
    clear_staging "$STAGING"
    exit 1
fi

if [ "$SEEN" != "$NOW" ]; then
    print_error "The config changed while the page was open, so nothing was published."
    print_action "Reload the hosting manager and make the edit again."
    print_info "Nothing was lost: the version on the branch is untouched."
    clear_staging "$STAGING" "$BASE_HASH_FILE"
    exit 1
fi

cp "$STAGING" "$CONF_REL"
PUBLISHED_SHA="$(sha1sum "$CONF_REL" | cut -d' ' -f1)"

# The candidate file is shared by every request. Another save or check may have
# staged its own edit while this one ran, and emptying that loses it silently.
clear_staging_if_ours() {
    if [ "$(sha1sum "$STAGING" 2>/dev/null | cut -d' ' -f1)" = "$PUBLISHED_SHA" ]; then
        clear_staging "$@"
    else
        print_info "A newer edit was staged while this one published. It was left in place."
    fi
}

# Exit 3, not 0: the page must not report "saved" for a press that saved nothing.
if git diff --quiet -- "$CONF_REL"; then
    print_success "No change: the config already matches what was submitted."
    clear_staging_if_ours "$STAGING"
    exit 3
fi

# Validating the candidate, in the clone where it has just been copied. Its own
# function so the skip below reads as one decision rather than a thirty line
# block under an else.
validate_candidate() {
    print_status "Validating the new config..."
    local log rc
    log="$(mktemp)"
    set +e
    SITES_CONF="$CLONE/$CONF_REL" \
        bash hostings/scripts/maintain_services.sh --check >"$log" 2>&1
    rc=$?
    set -e

    # Written whether it passed or failed: a report saying why the save was
    # refused is the most useful thing the page can show at that moment.
    {
        echo "Checked $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Command: maintain_services.sh --check, on the config being published"
        echo "Result:  $([ "$rc" -eq 0 ] && echo "config is valid" || echo "FAILED, exit $rc")"
        echo ""
        sed 's/\x1b\[[0-9;]*m//g' "$log"
    } > "${REPORT}.tmp"
    install -m 0644 -o root -g root "${REPORT}.tmp" "$REPORT"
    rm -f "${REPORT}.tmp"

    if [ "$rc" -ne 0 ]; then
        print_error "The new config is not valid, so it was NOT published."
        print_info "Nothing on the machine changed. What the check said:"
        sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -E '^❌|^⚠️' | head -n 20
        rm -f "$log"
        git checkout --quiet -- "$CONF_REL"
        exit 1
    fi
    rm -f "$log"
    print_success "Config is valid."
}

# Already checked? check_hostings.sh leaves the hash of what it found valid, and
# the page runs it on exactly these bytes before this script is ever reached. The
# whole check is 4.5s and one save used to run it three times: the page, here,
# and the Jenkins job.
#
# The marker is about the CONFIG only. Nothing here assumes the machine has not
# changed: the apply job checks again in its own workspace.
CHECKED_MARK="${MANAGER_HOME}/checked.sha1"
CANDIDATE_SHA="$PUBLISHED_SHA"
CHECKED_SHA="$(cat "$CHECKED_MARK" 2>/dev/null || true)"

if [ -n "$CHECKED_SHA" ] && [ "$CHECKED_SHA" = "$CANDIDATE_SHA" ]; then
    print_success "Already checked: these exact bytes passed, so the check was not repeated."
else
    validate_candidate
fi

# Consumed: the next save is a different config and must be checked on its own.
rm -f "$CHECKED_MARK"

# =============================================================================
# Commit and push
# =============================================================================
git -c user.name="${SAVED_BY} via the hosting manager" \
    -c user.email="hosting-manager@localhost" \
    commit --quiet -m "Edit hostings.conf from the hosting manager

Saved by: ${SAVED_BY}

Published by publish_hostings.sh on $(hostname), validated by
maintain_services.sh --check before this commit was made." \
    -- "$CONF_REL"

push_now() { git_app push --quiet "$HTTPS_REMOTE" "HEAD:$BRANCH"; }

_pushed=0
push_now && _pushed=1

# ONE RETRY, AND ONLY OVER A COMMIT THAT DID NOT TOUCH THIS FILE.
#
# The fetch at the top of this script and the push down here are seconds apart,
# and anything pushed to the branch in between makes the push a non-fast-forward.
# That is not a fault: on 2026-09-07 the branch took a commit from a laptop while
# the operator was saving a row, and the console reported "Your change was not
# saved" for a change that was perfectly valid.
#
# The retry is a rebase of THIS ONE COMMIT onto the new tip, and it is refused
# the moment the new commits touch hostings.conf: that is the case where
# replaying our file would delete somebody's edit, which is exactly what the
# stale-base guard above exists to prevent.
if [ "$_pushed" -ne 1 ]; then
    _base="$(git rev-parse HEAD^ 2>/dev/null || true)"
    git_app fetch --quiet "$HTTPS_REMOTE" "$BRANCH" && _tip="$(git rev-parse FETCH_HEAD 2>/dev/null || true)"

    if [ -n "${_tip:-}" ] && [ -n "$_base" ] \
       && [ -z "$(git diff --name-only "$_base" "$_tip" -- "$CONF_REL")" ]; then
        print_status "The branch moved while this was being checked. Replaying this commit on top."
        if git rebase --quiet "$_tip" >/dev/null 2>&1; then
            push_now && _pushed=1
        else
            git rebase --abort >/dev/null 2>&1 || true
        fi
    elif [ -n "${_tip:-}" ]; then
        print_error "The branch moved AND hostings.conf changed on it, so this edit was not replayed."
        print_action "Reload the page to get the new config, then make the edit again."
    fi
fi

if [ "$_pushed" -ne 1 ]; then
    print_error "Could not push. The commit exists locally and nothing was built."
    print_action "Fix the cause, then run this again: it will push the same commit."
    exit 1
fi

print_success "Pushed to origin/$BRANCH"
clear_staging_if_ours "$STAGING" "$BASE_HASH_FILE"

# =============================================================================
# Stop here. Applying is a separate act.
#
# This used to start the apply job, which was wrong: it was decided on
# 2026-08-02 that saving pushes and checks, the operator reads the drift report,
# and only then presses Apply. Applying on save lets a typo in a browser reach
# the sites a minute later, and the report is worth nothing if the change has
# already happened by the time it is read.
#
# So the check that just validated the config is kept, as the drift report the
# page shows next to its Apply button.
# =============================================================================
print_success "Nothing on the machine has changed yet."
print_status "Read the report, then press Apply."
