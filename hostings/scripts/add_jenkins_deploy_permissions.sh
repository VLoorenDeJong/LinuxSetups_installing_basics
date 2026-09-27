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
# Give the jenkins user exactly the privileges a deploy needs, and nothing else.
#
# A pipeline has to restart the Kestrel unit it just deployed into, which needs
# root. The lazy version is NOPASSWD: ALL, or a wildcard like /bin/systemctl *.
# Both hand full root to anyone who can make Jenkins run a shell command, which
# is anyone who can edit a Jenkinsfile or land a pull request. the server
# already carries wildcard chown/chmod grants on another account and they are
# on the ToDo as a root escalation path. Do not add a third.
#
# What this grants:
#   systemctl start|stop|restart|status <one of the app units in hostings.conf>
#   bash /usr/local/lib/linuxbasics/hostings/scripts/*.sh <args>
#
# THE PATHS ARE ABSOLUTE, AND THAT IS THE POINT. They used to be relative,
# matching what the Jenkinsfiles typed, and sudo resolved them inside Jenkins'
# own workspace. jenkins owns that workspace, so it could edit deploy_app.sh
# and then run it through sudo: arbitrary root from an account that only had to
# be able to start a build. Confirmed 2026-08-23.
#
# add_pipeline_scripts.sh keeps a root-owned clone at that path, refreshed by
# pulling from GitHub rather than by copying out of the workspace, which would
# put the hole back one step further away.
#
# Written as one explicit line per unit, generated from hostings.conf. Not a glob:
# `systemctl restart app-*` looks tight but sudo matches on the literal
# command string, so an attacker controls the rest of the argument list and can
# often reach a unit that was never meant to be in scope.
#
# Safe to re-run: regenerates the file and validates it before installing.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
CI_USER="${CI_USER:-jenkins}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    exit 1
fi

if ! id "$CI_USER" >/dev/null 2>&1; then
    print_error "User '$CI_USER' does not exist."
    print_action "Run add_jenkins.sh first, or set the user: sudo env CI_USER=<name> $0"
    exit 1
fi

if ! SYSTEMCTL_BIN="$(command -v systemctl)"; then
    print_error "systemctl not found."
    exit 1
fi

if ! BASH_BIN="$(command -v bash)"; then
    print_error "bash not found."
    exit 1
fi

# ABSOLUTE PATHS, UNDER A TREE THE DEPLOY ACCOUNT CANNOT WRITE.
#
# These used to be granted as the relative path the Jenkinsfiles typed, because
# sudo matches the literal command string. That resolved inside Jenkins' own
# workspace, which Jenkins owns: it could edit deploy_app.sh and then run it
# through sudo. Arbitrary root, from an account that only had to be able to
# start a build. Confirmed on 2026-08-23, both halves, without running it.
#
# add_pipeline_scripts.sh installs a root-owned clone at PIPELINE_ROOT, and
# every grant below names a path inside it. The workspace copy is still used
# for everything that needs no privilege.
PIPELINE_ROOT="${PIPELINE_ROOT:-/usr/local/lib/linuxbasics}"
PIPELINE_SCRIPTS=(
    "hostings/scripts/maintain_services.sh"
    # The refresher itself: a pipeline must be able to pull a newer copy of
    # the tree it runs from, or every job runs whatever was installed last.
    "hostings/scripts/add_pipeline_scripts.sh"
    "hostings/scripts/deploy_app.sh"
    "hostings/scripts/add_site_certificates.sh"
    "LinuxBasics/install_scripts/updates_install_and_clean.sh"
    "hostings/scripts/update_dns_apex.sh"
    # Apply reconciles GitHub as well as the machine: Envs decides which
    # branches a repo has.
    "hostings/scripts/provision_repo.sh"
    # Granted directly, not only through maintain_services.sh, because one task
    # per job means a job that writes a unit and a job that writes a vhost, each
    # calling its own script. maintain_services.sh still calls both for the
    # machine-wide case.
    "hostings/scripts/add_app_services.sh"
    "hostings/scripts/add_app_vhosts.sh"
    # The .NET install job. A package transaction, so it needs root, and it is
    # its own job rather than a step inside a release for the same reason.
    "LinuxBasics/install_scripts/add_dotnet.sh"
    # The WebAssembly builder container (item 139). Instead of the docker
    # group, which is root outright; the script itself refuses every mode but
    # publish, and only inside the workspace.
    "hostings/scripts/build_in_container.sh"
    # Docker application rows (item 140): builds the row's image and restarts
    # its unit. Refuses a checkout outside the workspace or a non-docker row.
    "hostings/scripts/deploy_docker_app.sh"
    # --refresh only, granted as a literal below. The apply keeps the console
    # clone level with the branch, because nothing else did: the page is built
    # from that clone, so a config pushed from anywhere else was invisible on it
    # until somebody saved in the browser and had the save refused for editing a
    # stale file.
)

# One literal, not a wildcard. --refresh fetches and resets the console clone
# and exits; the no-argument form commits and pushes, and Jenkins is not granted
# that. A `*` here would hand Jenkins both.
PIPELINE_SCRIPTS_LITERAL=(
    "hostings/scripts/publish_hostings.sh --refresh"
    # The git credential helper, so a job can check out a PRIVATE submodule of
    # a customer's repository. git invokes a helper as `helper <operation>` and
    # talks to it over stdin, so the operation is granted by name.
    #
    # NAMED RATHER THAN WILDCARDED, and the difference is the whole point: `*`
    # would also grant `--token <owner>`, which hands the jenkins account a
    # token for any owner on demand. These three are the credential protocol
    # and nothing else, and only `get` returns anything at all.
    #
    # WHAT IT STILL WIDENS, said plainly rather than buried: `get` returns a
    # token for whatever github.com URL is fed to it on stdin. The jenkins
    # account could already decide what root runs, because the pipeline tree is
    # pulled from a repository it can reach, so this is not a new path to root.
    # It is a new path to a token.
    #
    # store and erase are granted so a clone does not print a sudo password
    # prompt to stderr for two no-ops.
    "hostings/scripts/git_credential_github_app.sh get"
    "hostings/scripts/git_credential_github_app.sh store"
    "hostings/scripts/git_credential_github_app.sh erase"
)

# Scripts a pipeline runs with NO arguments. The `*` form above requires at
# least one, so a bare call matches nothing, sudo asks for a password, and the
# job dies with "a terminal is required to read the password" rather than
# anything naming the real problem. That is what the machine-update job did on
# 2026-08-11.
PIPELINE_SCRIPTS_BARE=(
    "hostings/scripts/add_pipeline_scripts.sh"
    "LinuxBasics/install_scripts/updates_install_and_clean.sh"
    # The same update in its own unit, so a Jenkins restart cannot kill apt.
    "hostings/scripts/run_updates_detached.sh"
    "LinuxBasics/install_scripts/add_dotnet.sh"
    # The drift banner is built from last-check.txt, and only this writes it.
    # Without it the page keeps showing the drift the apply just fixed, or
    # stays silent about drift the apply could not fix. Read-only: it runs
    # maintain_services.sh --check and writes one report file.
    "hostings/scripts/check_hostings.sh"
)

print_header "Jenkins deploy permissions"
print_status "Config: $SITES_CONF"
print_status "User:   $CI_USER"

UNITS=()
while IFS='|' read -r type name port path subdomain datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    type="$(echo "$type" | sed 's/#.*//' | xargs)"
    [ "$type" != "app" ] && continue
    name="$(echo "$name" | xargs)"
    [ -z "$name" ] && continue
    UNITS+=("app-${name}.service")
done < "$SITES_CONF"

# No app rows is not an error. The unit grants are per row, but the pipeline
# grants are not: the apply and deploy jobs need them whether or not this
# machine happens to run an application today. Refusing here meant a config of
# only websites could not have its sudoers file written at all, which is how
# the console-clone refresh grant could not be installed on 2026-09-03.
if [ ${#UNITS[@]} -eq 0 ]; then
    print_info "No app rows in $SITES_CONF, so no unit grants are written."
    print_status "The pipeline script grants do not depend on rows and still are."
else
    print_status "Units in scope: ${#UNITS[@]}"
fi

SUDOERS_FILE="/etc/sudoers.d/010_${CI_USER}-deploy"
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT

{
    echo "# Generated by add_jenkins_deploy_permissions.sh from hostings.conf"
    echo "# Do not edit by hand: the next run overwrites it. Edit the config instead."
    echo "#"
    echo "# One explicit command per unit, never a wildcard. sudo matches on the"
    echo "# literal string, so a glob would let the caller control the rest of the"
    echo "# argument list and reach units that are not meant to be in scope."
    echo ""
    for unit in "${UNITS[@]}"; do
        for verb in start stop restart status; do
            echo "${CI_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} ${verb} ${unit}"
        done
    done
    echo ""
    echo "# The apply and deploy pipelines. Absolute paths, under a tree that"
    echo "# ${CI_USER} cannot write: ${PIPELINE_ROOT}."
    echo "#"
    echo "# These were relative once, matching what the Jenkinsfiles typed, and"
    echo "# sudo resolved them inside Jenkins' own workspace. ${CI_USER} owns"
    echo "# that workspace, so it could edit a script and then run it through"
    echo "# sudo: arbitrary root from an account that only had to start a build."
    echo "#"
    echo "# What is left is still real and is not a bug: whoever can push to"
    echo "# this repository decides what root runs, because that is where the"
    echo "# tree is pulled from. The lock that matters is on who may push."
    echo "#"
    echo "# The trailing * requires at least one argument, so the apply job passes"
    echo "# --apply rather than running the script bare."
    for s in "${PIPELINE_SCRIPTS[@]}"; do
        echo "${CI_USER} ALL=(root) NOPASSWD: ${BASH_BIN} ${PIPELINE_ROOT}/${s} *"
    done
    echo ""
    echo "# The same scripts again with no argument at all, for the jobs that"
    echo "# take none. Listed separately so the rule above keeps meaning what it"
    echo "# says: everything else must still name what it is doing."
    for s in "${PIPELINE_SCRIPTS_BARE[@]}"; do
        echo "${CI_USER} ALL=(root) NOPASSWD: ${BASH_BIN} ${PIPELINE_ROOT}/${s}"
    done
    echo ""
    echo "# Exact command and argument, no wildcard. These scripts do something"
    echo "# else entirely when called differently, so the argument is part of"
    echo "# what is being granted rather than something the caller chooses."
    for s in "${PIPELINE_SCRIPTS_LITERAL[@]}"; do
        echo "${CI_USER} ALL=(root) NOPASSWD: ${BASH_BIN} ${PIPELINE_ROOT}/${s}"
    done
} > "$TMP_SUDOERS"

# A broken sudoers file can lock every account out of sudo on the machine.
# visudo -c on the temp file is the only thing standing between a typo here and
# a rescue boot, so it is not optional and its failure is fatal.
print_status "Validating the generated sudoers file..."
if ! visudo -cf "$TMP_SUDOERS" >/dev/null 2>&1; then
    print_error "Generated sudoers file is invalid, so nothing was installed."
    print_info "Output:"
    visudo -cf "$TMP_SUDOERS" || true
    exit 1
fi
print_success "Sudoers file is valid."

if [ -f "$SUDOERS_FILE" ] && cmp -s "$TMP_SUDOERS" "$SUDOERS_FILE"; then
    print_success "Permissions already correct, nothing changed."
else
    install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS_FILE"
    print_success "Installed $SUDOERS_FILE"
fi

# Prove it works rather than assuming. -l lists what the user may run; -n stops
# it prompting for a password, which would hang an unattended install.
print_status "Verifying the grant..."
# With no app rows there is no unit to test, so the pipeline grant is checked
# instead. Something is always verified rather than nothing.
if [ ${#UNITS[@]} -gt 0 ]; then
    SAMPLE_UNIT="${UNITS[0]}"
    if sudo -n -u "$CI_USER" sudo -n -l "$SYSTEMCTL_BIN" restart "$SAMPLE_UNIT" >/dev/null 2>&1; then
        print_success "Verified: $CI_USER may restart $SAMPLE_UNIT without a password."
    else
        print_info "Could not verify the grant from here."
        print_action "Check by hand: sudo -u $CI_USER sudo -l"
    fi
fi

if sudo -n -u "$CI_USER" sudo -n -l "$BASH_BIN" \
        "${PIPELINE_ROOT}/hostings/scripts/publish_hostings.sh" --refresh >/dev/null 2>&1; then
    print_success "Verified: $CI_USER may refresh the console clone."
else
    print_info "Could not verify the console-clone grant from here."
    print_action "Check by hand: sudo -u $CI_USER sudo -l"
fi

echo ""
print_status "Granted to $CI_USER, for these units:"
for unit in "${UNITS[@]}"; do
    print_status "  - $unit"
done
print_status "And these pipeline scripts, which run as root:"
for s in "${PIPELINE_SCRIPTS[@]}"; do
    print_status "  - $s"
done
print_action "Adding an app row to hostings.conf does NOT update this file."
print_action "Re-run this script after changing the config, or the new unit"
print_action "cannot be restarted by a pipeline and the deploy fails."

print_success "Jenkins deploy permissions configured."
