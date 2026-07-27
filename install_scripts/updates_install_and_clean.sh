#!/bin/bash

# Quiet by default; set to 1 for verbose output
VERBOSE_MODE=0
export VERBOSE_MODE

# Suppress confirmation prompts for apt
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prime sudo before any progress indicator starts.
#
# sudo writes its password prompt to /dev/tty, never to stdout/stderr — so a
# prompt raised inside a wrapped command is NOT captured by that command's
# ">$LOG 2>&1" redirect, and the progress bar's "\r\033[K" redraw erases it from
# the screen every 0.2s. The result is an invisible prompt, an empty log, and a
# spinner that turns forever while sudo waits for input that never comes.
# Asking here, on a clean screen, makes the prompt visible and every later sudo
# call non-interactive.
ensure_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    printf "\e[34m🔐 Administrator access required\e[0m\n"
    if ! sudo -v; then
        printf "\e[31m❌ sudo authentication failed — cannot continue\e[0m\n"
        exit 1
    fi
}
ensure_sudo

# Single log for every wrapped apt command. Defined at top level so it is set
# in verbose mode too — a redirect to an unset $APT_LOG is an ambiguous-redirect
# error, not a silent no-op.
APT_LOG="/tmp/updates_install_and_clean.log"

# --- Inline utility functions (always defined, no sourcing required) ---
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

print_header() {
    printf "\n\e[36m=== %s ===\e[0m\n" "$1"
}

# Function to show progress with dots
show_progress() {
    local message="$1"
    local command="$2"
    local interval="${3:-3}"  # Default 3 seconds between dots
    local timeout="${4:-300}"  # Default 5 minute timeout

    echo -e "\e[34m${message}\e[0m"

    # Start the command in background
    eval "$command" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)

    # Show progress dots while command runs
    while kill -0 $cmd_pid 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep $interval || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            printf "\n\e[31m❌ Command timed out after %d seconds\e[0m\n" "$timeout"
            kill -TERM $cmd_pid 2>/dev/null || true
            sleep 2
            kill -KILL $cmd_pid 2>/dev/null || true
            return 1
        fi
    done

    # Wait for command to complete and get exit code
    wait $cmd_pid
    local exit_code=$?

    echo  # New line after dots
    return $exit_code
}

# Watch-only variant for irreversible package transactions (full-upgrade, install -f,
# dpkg -i, dpkg --configure -a): never signals the child, only reports elapsed time.
show_progress_watch_only() {
    local message="$1"
    local command="$2"
    local interval="${3:-3}"  # Default 3 seconds between dots

    echo -e "\e[34m${message}\e[0m"

    eval "$command" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)

    while kill -0 $cmd_pid 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep $interval || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done

    wait $cmd_pid
    local exit_code=$?

    echo  # New line after dots
    return $exit_code
}

# Watch-only spinner + progress bar: never signals the child (same regime as
# show_progress_watch_only), but renders a live bar from apt's machine-readable
# status lines ("pmstatus:...:PCT:desc" / "dlstatus:...") that land in the log
# when apt-get runs with -o APT::Status-Fd=1.
show_progress_bar_watch_only() {
    local message="$1"
    local command="$2"
    local logfile="$3"

    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local width=28
    local empty_bar full_bar
    empty_bar=$(printf '░%.0s' $(seq 1 $width))
    full_bar=$(printf '█%.0s' $(seq 1 $width))

    echo -e "\e[34m${message}\e[0m"

    eval "$command" &
    local cmd_pid=$!
    local tick=0

    while kill -0 $cmd_pid 2>/dev/null; do
        local frame="${spinner[tick % 10]}"
        tick=$((tick + 1))

        local line pct="" desc="" parsed=""
        line=$(grep -E '^(pmstatus|dlstatus):' "$logfile" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then
            # apt writes "type:name:percent:message", but a multi-arch name
            # carries its own colon ("pmstatus:libc6:amd64:37.5000:Unpacking"),
            # so the percent is NOT at a fixed field index — cut -f3 grabbed
            # "amd64" and the bar stayed stuck on "working" for the whole dpkg
            # phase. Take the first decimal field at or after 3 as the percent,
            # everything after it as the description (which may contain colons).
            parsed=$(printf '%s' "$line" | awk -F: '{
                for (i = 3; i <= NF; i++)
                    if ($i ~ /^[0-9]+\.[0-9]+$/) {
                        d = $(i+1)
                        for (j = i + 2; j <= NF; j++) d = d ":" $j
                        printf "%d\t%s", $i, d
                        exit
                    }
            }')
            pct=${parsed%%$'\t'*}
            desc=${parsed#*$'\t'}
        fi

        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            local filled=$((pct * width / 100))
            printf '\r\033[K[%s%s] %s %3d%%  %.40s' "${full_bar:0:filled}" "${empty_bar:0:width-filled}" "$frame" "$pct" "$desc"
        else
            printf '\r\033[K[%s] %s  …   working' "$empty_bar" "$frame"
        fi

        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep 0.2 || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done

    wait $cmd_pid
    local exit_code=$?

    printf '\r\033[K'  # Clear the bar line before normal output resumes
    return $exit_code
}

# Function to check and fix DPKG locks (calls dedicated script)
check_and_fix_dpkg_lock() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fix_script="$script_dir/fix_dpkg_lock.sh"
    
    if [ -f "$fix_script" ]; then
        echo -e "\e[34m🔧 Checking and fixing DPKG locks...\e[0m"
        if bash "$fix_script"; then
            echo -e "\e[32m✅ DPKG lock check/fix completed\e[0m"
            return 0
        else
            echo -e "\e[31m❌ DPKG lock fix failed, continuing anyway...\e[0m"
            return 1
        fi
    else
        echo -e "\e[33m⚠️  fix_dpkg_lock.sh not found, proceeding without DPKG lock check\e[0m"
        return 1
    fi
}

# Enable or disable confirmation prompts (true = ask, false = skip)
ASK_CONFIRMATION=false

# Function to prompt the user if confirmation is enabled
ask_user() {
    if [[ "$ASK_CONFIRMATION" == true ]]; then
        read -r -p "$1 (Y/n): " choice < /dev/tty || choice="n"
        choice=${choice:-Y}  # Default to "Y" if no input is given
        [[ "$choice" =~ ^[Yy]$ ]]
    else
        return 0  # Automatically proceed without asking
    fi
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

# needrestart's kernel-upgrade dialog can grab the terminal during any apt
# transaction and silently block an unattended run (and killing it corrupts
# the transaction). It is informational only — disable it machine-wide, once.
NEEDRESTART_CONF="/etc/needrestart/conf.d/99-no-kernel-dialog.conf"
if [ -d /etc/needrestart ] && [ ! -f "$NEEDRESTART_CONF" ]; then
    print_status "Disabling needrestart's kernel-upgrade dialog (informational only)"
    mkdir -p /etc/needrestart/conf.d
    echo '$nrconf{kernelhints} = -1;' > "$NEEDRESTART_CONF"
fi

# Ask for system update confirmation
if ask_user "Do you want to update and upgrade the system?"; then
    # Check and fix any DPKG locks before proceeding with package operations
    check_and_fix_dpkg_lock
    
    if [ "${VERBOSE_MODE:-0}" -eq 1 ]; then
        echo -e "\e[34m🔧 Running apt-get update (verbose mode)\e[0m"
        if sudo apt-get update; then
            echo -e "\e[32m✅ Package lists updated successfully\e[0m"
        else
            echo -e "\e[31m❌ Package list update failed\e[0m"
            exit 1
        fi

        echo -e "\e[34m🔧 Running apt-get full-upgrade (verbose mode)\e[0m"
        if sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"; then
            echo -e "\e[32m✅ System upgrade completed successfully\e[0m"
        else
            echo -e "\e[31m❌ System upgrade failed\e[0m"
            exit 1
        fi
    else
        if show_progress "📦 Updating package lists" "sudo -n apt-get update -qq >$APT_LOG 2>&1"; then
            echo -e "\e[32m✅ Package lists updated successfully\e[0m"

            # APT::Status-Fd=1 writes machine-readable percent lines into the
            # log for the bar. -qq is omitted so the log keeps apt's full output
            # and a failure is diagnosable — verified on the target that -qq
            # does NOT suppress the status lines, so this is a readability
            # choice, not a requirement of the progress bar.
            # env vars go AFTER sudo via `env`: `sudo VAR=x cmd` is rejected
            # outright by sudoers policies that don't grant SETENV.
            # sudo -n is mandatory for anything run inside a progress wrapper.
            # The wrapper backgrounds the command, and sudo reads its password
            # from /dev/tty (never stdin), so a prompt here is invisible: the
            # log redirect can't capture it and the bar's redraw erases it —
            # the job just stops and the spinner turns forever. ensure_sudo
            # above has already primed the cache; -n turns any remaining
            # authentication failure into an immediate, logged error.
            if show_progress_bar_watch_only "⬆️ Upgrading system packages (irreversible — will not be interrupted)" "sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get full-upgrade -y -o APT::Status-Fd=1 -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" >$APT_LOG 2>&1" "$APT_LOG"; then
                echo -e "\e[32m✅ System upgrade completed successfully\e[0m"
            else
                echo -e "\e[31m❌ System upgrade failed — last apt output:\e[0m"
                tail -10 "$APT_LOG" 2>/dev/null || true
                exit 1
            fi
        else
            echo -e "\e[31m❌ Package list update failed — last apt output:\e[0m"
            tail -10 "$APT_LOG" 2>/dev/null || true
            exit 1
        fi
    fi

    # Ask for cleanup confirmation
    if ask_user "Do you want to clean up unused packages?"; then
        # A long upgrade can outlive sudo's credential timeout (15m by default),
        # which would make every -n call below fail. Re-prime here, in the
        # foreground, where a prompt is actually visible.
        ensure_sudo

        # Remove unused packages
        if [ "${VERBOSE_MODE:-0}" -eq 1 ]; then
            echo -e "\e[34m🔧 Running apt-get autoremove (verbose mode)\e[0m"
            if sudo apt-get autoremove -y; then
                echo -e "\e[32m✅ Unused packages removed\e[0m"
            fi
        # autoremove uninstalls packages — irreversible dpkg transaction, never kill it
        elif show_progress_watch_only "🗑️ Removing unused packages (will not be interrupted)" "sudo -n apt-get autoremove -y -qq >$APT_LOG 2>&1" 3; then
            echo -e "\e[32m✅ Unused packages removed\e[0m"
        else
            echo -e "\e[31m❌ Removing unused packages failed — last apt output:\e[0m"
            tail -10 "$APT_LOG" 2>/dev/null || true
        fi

        # Purge leftover configuration files, only if any exist
        leftover_configs=$(dpkg -l | awk '/^rc/ { print $2 }')
        if [ -n "$leftover_configs" ]; then
            # Flatten newlines to spaces so it works as a single command argument list
            leftover_configs_flat=$(echo "$leftover_configs" | tr '\n' ' ')
            if [ "${VERBOSE_MODE:-0}" -eq 1 ]; then
                echo -e "\e[34m🔧 Removing leftover configurations (verbose mode)\e[0m"
                if sudo apt-get purge -y $leftover_configs_flat; then
                    echo -e "\e[32m✅ Leftover configurations removed\e[0m"
                fi
            # purge modifies package state — irreversible dpkg transaction, never kill it
            elif show_progress_watch_only "🧹 Removing leftover configurations (will not be interrupted)" "sudo -n apt-get purge -y -qq $leftover_configs_flat >$APT_LOG 2>&1" 3; then
                echo -e "\e[32m✅ Leftover configurations removed\e[0m"
            else
                echo -e "\e[31m❌ Removing leftover configurations failed — last apt output:\e[0m"
                tail -10 "$APT_LOG" 2>/dev/null || true
            fi
        fi

        # Clean up cached packages
        if [ "${VERBOSE_MODE:-0}" -eq 1 ]; then
            echo -e "\e[34m🔧 Cleaning package cache (verbose mode)\e[0m"
            if sudo apt-get autoclean -y && sudo apt-get clean -y; then
                echo -e "\e[32m✅ Package cache cleaned\e[0m"
            fi
        elif show_progress "🧽 Cleaning package cache" "sudo -n apt-get autoclean -y -qq >$APT_LOG 2>&1 && sudo -n apt-get clean -y -qq >>$APT_LOG 2>&1"; then
            echo -e "\e[32m✅ Package cache cleaned\e[0m"
        else
            echo -e "\e[31m❌ Cleaning package cache failed — last apt output:\e[0m"
            tail -10 "$APT_LOG" 2>/dev/null || true
        fi

        echo -e "\e[32m✅ System cleanup completed!\e[0m"
    fi
fi
