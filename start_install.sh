#!/bin/bash
#
# Standalone installer for the LinuxBasics scripts.
#
# HOW TO USE THIS FILE
# --------------------
# Everything in the two arrays below is commented out on purpose. Nothing runs
# until you say so. Read the one-line description next to each entry, delete the
# leading "#" on the ones you want, then run:
#
#     sudo bash install_scripts/start_install.sh
#
# The install happens in two phases. Phase 1 updates the operating system and
# ends with a reboot; Phase 2 installs applications on the freshly rebooted
# system. Re-run the same command after the reboot and it continues with
# Phase 2 automatically.
#
# Order matters. Keep the entries in the order given — they are arranged so
# each one has what it needs from the ones before it.
#
# If you are consuming these scripts from your own repository, you do not need
# this file: point your own start_install.sh at this directory instead.

print_status() {
    printf "\e[34m🔧 %s\e[0m\n" "$1"
}

print_success() {
    printf "\e[32m✅ %s\e[0m\n" "$1"
}

print_warning() {
    printf "\e[33m⚠️ %s\e[0m\n" "$1"
}

print_error() {
    printf "\e[31m❌ %s\e[0m\n" "$1"
}

# =============================================================================
# CONFIGURATION
# =============================================================================
# Set to 0 to skip the reboot prompt, set to 1 to ask before rebooting
ASK_FOR_REBOOT=0

# Optional Ubuntu Pro attach (off by default — it needs a subscription token).
# Turn it on either way:
#   sudo env PRO_TOKEN=<YOUR_PRO_TOKEN> ./start_install.sh   (unattended)
#   set INSTALL_UBUNTU_PRO=1 below                           (prompts for the token)
# Never put a real token in this file.
INSTALL_UBUNTU_PRO=0

debugMode=0
verboseMode=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -q|--quiet)
            verboseMode=0
            shift
            ;;
        -v|--verbose)
            verboseMode=1
            shift
            ;;
        -d|--debug)
            debugMode=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Installer for the LinuxBasics scripts"
            echo ""
            echo "Options:"
            echo "  -q, --quiet     Run in quiet mode (less output) [default]"
            echo "  -v, --verbose   Run in verbose mode (more output)"
            echo "  -d, --debug     Enable debug mode (bash -x)"
            echo "  -h, --help      Show this help message"
            echo ""
            echo "Configuration:"
            echo "  Uncomment the scripts you want in the PHASE1_SCRIPTS and"
            echo "  PHASE2_SCRIPTS arrays inside this file. Everything is"
            echo "  commented out until you choose."
            echo ""
            echo "Optional Ubuntu Pro:"
            echo "  Runs add_ubuntu_pro.sh when PRO_TOKEN is set, or INSTALL_UBUNTU_PRO=1 in this file"
            echo ""
            echo "Examples:"
            echo "  sudo $0                    # Run the phases you enabled"
            echo "  sudo $0 --quiet           # Quiet mode"
            echo "  sudo $0 --debug           # Debug mode"
            echo "  sudo env PRO_TOKEN=<YOUR_PRO_TOKEN> $0   # Also attach Ubuntu Pro"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Export verbosity setting for child scripts
export VERBOSE_MODE="$verboseMode"

# Check if running with sudo privileges
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\e[31m❌ This script requires sudo privileges to run properly.\e[0m"
    echo -e "\e[33m💡 Please run with: \e[36msudo $0\e[0m"
    echo -e "\e[33m   This will avoid password prompts during installation.\e[0m"
    exit 1
fi

# Get the directory where this script resides. Every script lives right here,
# so there is no submodule to fetch and no second location to search.
SCRIPT_DIR=$(dirname "$0")
INSTALL_DIR="$(cd "$SCRIPT_DIR" && pwd)/install_scripts"

resolve_script() {
    local name="$1"
    if [ -f "$INSTALL_DIR/$name" ]; then
        echo "$INSTALL_DIR/$name"
    else
        return 1
    fi
}

# Set common parameters — resolve the real invoking user, not root's own $HOME
if [ -n "$SUDO_USER" ]; then
    USER_PARAM="$SUDO_USER"
else
    USER_PARAM="$(logname 2>/dev/null || whoami)"
fi

# =============================================================================
# TWO-PHASE INSTALL
# Phase 1 upgrades the OS (new systemd/kernel) and ends with a reboot —
# continuing to install on a half-upgraded systemd is how package
# post-install scripts start failing with "Could not execute systemctl".
# Phase 2 (everything else) runs on the clean, fully upgraded system.
# A marker file tracks completion; re-running this script after the Phase 1
# reboot continues with Phase 2 automatically.
# =============================================================================
STATE_DIR="/var/lib/linuxbasics"
PHASE1_MARKER="$STATE_DIR/phase1.done"

# -----------------------------------------------------------------------------
# PHASE 1 — get the operating system into a clean, up-to-date state.
# Ends with a reboot. Uncomment what you want; the order is deliberate.
# Format: "script_name" or "script_name:param1" or "script_name:param1:param2"
# -----------------------------------------------------------------------------
PHASE1_SCRIPTS=(
#    "set_scripts_executable.sh"        # Marks the scripts runnable — first, so everything after it can start
#    "check_shell_syntax.sh"            # Checks every script here for typos and stops before anything is changed
#    "cleanup_repositories.sh"          # Removes broken or duplicate software sources that make "apt update" fail
#    "fix_dpkg_lock.sh"                 # Clears a stuck package manager ("could not get lock /var/lib/dpkg")
#    "fix_xauthority.sh"                # Silences the .Xauthority permission warning shown at login
#    "add_ubuntu_pro.sh"                # Adds years of extra security updates (free for personal use on up to 5 machines; needs a token)
#    "updates_install_and_clean.sh"     # Installs every pending OS update, then deletes the leftovers
#    "add_ufw.sh"                       # Switches the firewall on and keeps SSH reachable
#    "add_ssh.sh"                       # Installs the SSH server so you can log in remotely
#    "add_bash_show_branch_name.sh"     # Shows the current git branch in your shell prompt
)

# -----------------------------------------------------------------------------
# PHASE 2 — applications, installed on the upgraded and rebooted system.
# -----------------------------------------------------------------------------
PHASE2_SCRIPTS=(
#    "set_scripts_executable.sh"        # Marks the scripts runnable — same two checks that opened Phase 1
#    "check_shell_syntax.sh"            # Checks every script here for typos and stops before anything is changed
#    "add_java.sh"                      # Installs Java (the JDK version matching your Ubuntu release)
#    "add_docker.sh"                    # Installs Docker for running apps in containers
#    "add_apache_webserver.sh"          # Installs the Apache web server for hosting websites (opens its own ports)
#    "add_webmin.sh"                    # Installs Webmin, a web page for administering this server
#    "add_smb.sh"                       # Shares folders over the network so Windows and Mac can open them
#    "add_rsync.sh"                     # Installs rsync, used for fast copying and backups
    # Keep this last, so the login banner reflects the finished system
    # (failed services, disk and memory use) rather than a half-installed one
#    "configure_motd_services.sh"       # Replaces the login banner with disk, memory and service status
)

# reboot.sh is the one script with no array entry. It restarts the machine, and
# this file is the only thing allowed to call it — at the end of Phase 1, and
# after a successful Phase 2 unless you set ASK_FOR_REBOOT=1 and decline. Adding
# it to an array would reboot mid-run, before the scripts after it had gone.

# Nothing below this line needs editing to choose what gets installed.
# =============================================================================

# Ubuntu Pro can also be switched on without editing the list above, by giving a
# token on the command line or setting INSTALL_UBUNTU_PRO=1 at the top. It has to
# run before updates_install_and_clean.sh, because the extra package sources it
# unlocks must exist before the upgrade goes looking for them — so it is inserted
# in front of that entry rather than appended at the end.
if [ -n "$PRO_TOKEN" ] || [ "$INSTALL_UBUNTU_PRO" -eq 1 ]; then
    # Export so the child script inherits the token when it was set in this file
    export PRO_TOKEN
    case " ${PHASE1_SCRIPTS[*]} " in
        *" add_ubuntu_pro.sh "*)
            # Already enabled in the list; leave it where the reader put it,
            # otherwise the subscription would be attached twice in one run
            ;;
        *)
            _phase1_with_pro=()
            for _entry in "${PHASE1_SCRIPTS[@]}"; do
                [ "${_entry%%:*}" = "updates_install_and_clean.sh" ] &&
                    _phase1_with_pro+=("add_ubuntu_pro.sh")
                _phase1_with_pro+=("$_entry")
            done
            case " ${_phase1_with_pro[*]} " in
                *" add_ubuntu_pro.sh "*) ;;
                *) _phase1_with_pro+=("add_ubuntu_pro.sh") ;;   # updates not enabled
            esac
            PHASE1_SCRIPTS=("${_phase1_with_pro[@]}")
            unset _phase1_with_pro _entry
            ;;
    esac
fi

if [ -f "$PHASE1_MARKER" ]; then
    CURRENT_PHASE=2
    SCRIPT_PARAMS=("${PHASE2_SCRIPTS[@]}")
    echo -e "\e[34m🚀 Phase 1 already completed — beginning Phase 2 (applications)...\e[0m"
else
    CURRENT_PHASE=1
    SCRIPT_PARAMS=("${PHASE1_SCRIPTS[@]}")
    echo -e "\e[34m🚀 Beginning Phase 1 (OS preparation — ends with a reboot)...\e[0m"
fi

# Nothing selected: stop here rather than marking the phase done and rebooting a
# machine on which no work was actually performed.
if [ ${#SCRIPT_PARAMS[@]} -eq 0 ]; then
    print_warning "No scripts are enabled for phase $CURRENT_PHASE."
    print_status "Open $0 and remove the leading '#' from the entries you want."
    exit 1
fi

# Configure reboot behavior based on setting
if [ "$ASK_FOR_REBOOT" -eq 1 ]; then
    # Ask user about reboot preference
    printf "\e[34mDo you want to reboot after all scripts complete successfully? [Y/n]:\e[0m "
    read -r REBOOT_CHOICE < /dev/tty || REBOOT_CHOICE="n"
    # Default to Y if empty input or Y/y, otherwise no reboot
    case "$REBOOT_CHOICE" in
        [Nn]*)
            SHOULD_REBOOT=false
            ;;
        *)
            SHOULD_REBOOT=true
            ;;
    esac
else
    # Don't ask for reboot - default to automatic reboot on success
    SHOULD_REBOOT=true
fi

# Track missing scripts
MISSING=()

# Check for existence of all scripts first
for script_entry in "${SCRIPT_PARAMS[@]}"; do
    # Extract just the script name (before any colon)
    script_name=$(echo "$script_entry" | cut -d':' -f1)
    if ! resolve_script "$script_name" >/dev/null; then
        MISSING+=("$script_name")
    fi
done

# If any scripts are missing, display and exit
if [ ${#MISSING[@]} -gt 0 ]; then
    echo -e "\e[31m🚫 The following script(s) are missing:\e[0m"
    for script in "${MISSING[@]}"; do
        echo -e "\e[31m - $script\e[0m"
    done
    exit 1
fi

# Run the scripts
ALL_SUCCESS=true
FAILED_SCRIPTS=()

# Function to run DPKG lock fix
run_lock_fix() {
    local fix_script
    fix_script=$(resolve_script "fix_dpkg_lock.sh")
    if [[ -n "$fix_script" && -f "$fix_script" ]]; then
        echo -e "\e[34m🔧 Checking and fixing DPKG locks...\e[0m"
        if bash "$fix_script"; then
            echo -e "\e[32m✅ DPKG locks resolved\e[0m"
            return 0
        else
            echo -e "\e[33m⚠️  DPKG lock fix failed, continuing anyway...\e[0m"
            return 1
        fi
    else
        echo -e "\e[33m⚠️  fix_dpkg_lock.sh not found, skipping lock check\e[0m"
        return 1
    fi
}

# Run initial lock fix before starting any scripts
run_lock_fix

for script_entry in "${SCRIPT_PARAMS[@]}"; do
    # Parse script entry: "script_name:param1:param2" or just "script_name".
    # IFS parsing leaves the params empty when there is no ':' — cut would
    # echo the whole entry back, passing the script its own name as arguments
    IFS=':' read -r script_name param1 param2 _ <<< "$script_entry"

    # Skip running fix_dpkg_lock.sh again since we handle it separately
    if [[ "$script_name" == "fix_dpkg_lock.sh" ]]; then
        echo -e "\e[34m⏭️  Skipping $script_name (handled separately)\e[0m"
        continue
    fi

    # Run lock fix before each script (except the lock fix itself)
    run_lock_fix

    echo -e "\e[34m🚀 Running: $script_name\e[0m"

    # Choose execution method based on debugMode
    if [ "$debugMode" -eq 1 ]; then
        RUN_CMD=(bash -x)
    else
        RUN_CMD=(bash)
    fi

    # Build the argv array with parameters (no eval — avoids word-splitting/injection issues)
    if ! script_path=$(resolve_script "$script_name"); then
        echo -e "\e[31m❌ Failed: $script_name (script disappeared mid-run)\e[0m"
        ALL_SUCCESS=false
        FAILED_SCRIPTS+=("$script_name (not found)")
        continue
    fi
    CMD=("${RUN_CMD[@]}" "$script_path")
    [ -n "$param1" ] && CMD+=("$param1")
    [ -n "$param2" ] && CMD+=("$param2")

    # Execute the command
    if "${CMD[@]}"; then
        echo -e "\e[32m✅ Finished: $script_name\e[0m"
    else
        exit_code=$?
        echo -e "\e[31m❌ Failed: $script_name (exit code: $exit_code)\e[0m"
        echo -e "\e[33m💡 Check the error messages above for details\e[0m"
        echo -e "\e[33m📂 Script location: $script_path\e[0m"
        echo -e "\e[33m🔍 To debug, run manually: sudo ${CMD[*]}\e[0m"
        ALL_SUCCESS=false
        FAILED_SCRIPTS+=("$script_name (exit code: $exit_code)")
    fi
    echo "" # Add spacing between scripts
done

# Phase 1 success: mark it done and reboot — Phase 2 must not run on the
# not-yet-rebooted systemd/kernel from the upgrade
if $ALL_SUCCESS && [ "$CURRENT_PHASE" -eq 1 ]; then
    mkdir -p "$STATE_DIR"
    touch "$PHASE1_MARKER"
    echo -e "\e[32m🎉 Phase 1 completed successfully!\e[0m"
    echo -e "\e[33m💡 After the reboot, re-run this script to continue with Phase 2:\e[0m"
    echo -e "\e[36m   sudo $0\e[0m"
    # Single reboot authority: reboot.sh (it owns its own countdown)
    bash "$(resolve_script reboot.sh)"
elif $ALL_SUCCESS && $SHOULD_REBOOT; then
    echo -e "\e[32m🎉 All scripts completed successfully!\e[0m"
    # Single reboot authority: reboot.sh (it owns its own countdown)
    bash "$(resolve_script reboot.sh)"
elif $ALL_SUCCESS; then
    echo -e "\e[32m🎉 All scripts completed successfully! No reboot requested.\e[0m"
else
    echo -e "\e[33m⚠️  Installation completed with some failures.\e[0m"
    echo -e "\e[31m💥 Failed scripts:\e[0m"
    for failed_script in "${FAILED_SCRIPTS[@]}"; do
        echo -e "\e[31m - $failed_script\e[0m"
    done
    if $SHOULD_REBOOT; then
        printf "\e[33m❓ Some scripts failed. Do you still want to reboot? [y/N]: \e[0m"
        read -r REBOOT_ANYWAY < /dev/tty || REBOOT_ANYWAY="n"
        case "$REBOOT_ANYWAY" in
            [Yy]*)
                # Single reboot authority: reboot.sh (owns its own countdown)
                bash "$(resolve_script reboot.sh)"
                ;;
            *)
                echo -e "\e[33m🚫 Reboot skipped due to failed scripts.\e[0m"
                ;;
        esac
    else
        echo -e "\e[33m🚫 No reboot requested.\e[0m"
    fi
    exit 1
fi
