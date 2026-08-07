#!/bin/bash

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

# Function to run commands with appropriate privileges
run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        # Already running as root, no sudo needed
        "$@"
    else
        # Not root, use sudo
        sudo "$@"
    fi
}

# Watch-only progress: prints dots while the command runs but never signals
# it — these are irreversible package transactions that must not be killed.
# Output is kept in a log and the tail is shown on failure — a bare "failed"
# with no reason is undebuggable.
FIX_DPKG_LOG="/tmp/fix_dpkg_lock.log"
run_watched() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" >>"$FIX_DPKG_LOG" 2>&1 &
    local watch_pid=$!
    while kill -0 "$watch_pid" 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo
    wait "$watch_pid"
    local exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo -e "\e[31m❌ Failed (exit $exit_code) — last output (full log: $FIX_DPKG_LOG):\e[0m"
        tail -15 "$FIX_DPKG_LOG" 2>/dev/null || true
    fi
    return $exit_code
}

# An sshd that outlives its unit keeps port 22 bound, so ssh.socket cannot
# bind, openssh-server fails to configure, and every later apt run fails with
# it. Reported, never killed: signalling it can cut the session running this.
check_orphaned_sshd() {
    if ! command -v ss >/dev/null 2>&1; then
        print_warning "ss not found, skipping the port 22 ownership check"
        return 0
    fi

    local pids
    pids=$(run_privileged ss -H -ltnp 'sport = :22' 2>/dev/null \
        | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    [ -z "$pids" ] && return 0

    # A listener is only orphaned when neither unit owns it any more
    if systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket; then
        return 0
    fi

    print_error "Port 22 is held by an sshd that no longer belongs to ssh.service or ssh.socket:"
    for pid in $pids; do
        ps -p "$pid" -o pid,etime,cmd --no-headers 2>/dev/null | sed 's/^/   /'
    done
    echo ""
    print_error "ssh.socket cannot bind while that runs, so openssh-server fails to"
    print_error "configure and every apt operation after it fails too."
    echo ""
    echo -e "\e[33m   Clear it, then run this again. Over a remote session, reboot:\e[0m"
    echo -e "\e[33m     sudo reboot\e[0m"
    echo ""
    echo -e "\e[33m   At the keyboard, or to keep the machine up:\e[0m"
    for pid in $pids; do
        echo -e "\e[33m     sudo kill $pid\e[0m"
    done
    echo -e "\e[33m     sudo systemctl start ssh.socket\e[0m"
    return 1
}

# Function to find processes using dpkg
find_dpkg_processes() {
    local processes=$(lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
    echo "$processes"
}

# Function to clean package cache
clean_package_cache() {
    echo -e "\e[34m🔄 Cleaning package cache...\e[0m"

    # Remove corrupted package cache files (files only, preserve subdirectories)
    run_privileged rm -f /var/cache/apt/*.bin
    run_privileged find /var/lib/apt/lists -maxdepth 1 -type f -delete

    # Update package lists (quiet mode, with progress — this can take a while)
    run_privileged apt-get clean -qq
    run_watched "📦 Updating package lists..." run_privileged apt-get update -qq --fix-missing
}

# Better lock detection - check for actual lock files AND processes
check_dpkg_lock() {
    local lock_detected=false
    
    # Check if lock files exist AND are being used by processes
    if [ -f "/var/lib/dpkg/lock-frontend" ]; then
        local processes=$(find_dpkg_processes)
        if [ -n "$processes" ]; then
            lock_detected=true
        fi
    fi
    
    # Alternative: Check if dpkg/apt commands are actually blocked
    if ! $lock_detected; then
        # Try a simple dpkg status check (less likely to fail for other reasons).
        # timeout runs a program, not a shell function — build the real command line
        local audit_cmd=(timeout 3 dpkg --audit)
        if [ "$EUID" -ne 0 ]; then
            audit_cmd=(timeout 3 sudo dpkg --audit)
        fi
        if ! "${audit_cmd[@]}" >/dev/null 2>&1; then
            # Double-check with fuser to see if lock files are actually in use
            if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
               fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
                lock_detected=true
            fi
        fi
    fi
    
    echo $lock_detected
}

echo -e "\e[34m🔍 Checking for dpkg/lock-frontend and package cache issues...\e[0m"

# Nothing below can succeed while port 22 is held by a unit-less sshd
check_orphaned_sshd || exit 1

# Test if we have a real dpkg lock issue
LOCK_STATE="$(check_dpkg_lock)"

# Half-configured packages (an install interrupted mid-configure, e.g. by a
# killed prompt or lost session) hold no lock but still fail every later apt
# run with "Errors were encountered while processing" — detect and heal those too
audit_cmd=(dpkg --audit)
[ "$EUID" -ne 0 ] && audit_cmd=(sudo dpkg --audit)
PENDING_CONFIG=false
if [ -n "$("${audit_cmd[@]}" 2>/dev/null)" ]; then
    PENDING_CONFIG=true
fi

if [ "$LOCK_STATE" = "false" ] && [ "$PENDING_CONFIG" = "false" ]; then
    echo -e "\e[32m✅ No dpkg lock or pending configuration detected. System is ready for package operations.\e[0m"
    exit 0
elif [ "$LOCK_STATE" = "true" ]; then
    echo -e "\e[33m⚠️  dpkg lock detected. Attempting to fix...\e[0m"
else
    echo -e "\e[33m⚠️  Half-configured packages detected (interrupted install). Repairing...\e[0m"
fi

# Lock-specific steps (1-3) only apply when a lock was actually detected;
# a pure pending-configuration repair skips straight to dpkg --configure -a
if [ "$LOCK_STATE" = "true" ]; then

# Step 1: Wait for any process holding the dpkg lock to exit on its own.
# A live dpkg/apt process must never be killed — SIGKILL mid-write can corrupt
# package state. This is a watch-only wait: it reports elapsed time but never
# signals the holder.
echo -e "\e[34m🔄 Waiting for dpkg lock holders to finish...\e[0m"

# Fifteen minutes, not two.
#
# The holder on a freshly booted machine is almost always unattended-upgrades,
# which systemd starts a few minutes after boot. On a Pi that run takes ten
# minutes or more, so a two-minute wait was guaranteed to give up on the one
# case it exists to handle, and the installer then looped on it.
#
# Waiting costs nothing. It is a watch-only wait: elapsed time is reported and
# the holder is never signalled, because SIGKILL mid-write corrupts package
# state and that is a far worse afternoon than waiting.
wait_timeout="${DPKG_WAIT_TIMEOUT:-900}"
wait_interval=5
elapsed=0
dpkg_processes=$(find_dpkg_processes)

if [ -n "$dpkg_processes" ]; then
    # The PID alone is useless: it says something is running, not what, and not
    # whether waiting is the right answer. Print the command line and how long
    # it has been going.
    echo -e "\e[33m📋 Holding the lock:\e[0m"
    for pid in $dpkg_processes; do
        ps -p "$pid" -o pid,etime,cmd --no-headers 2>/dev/null | sed 's/^/   /'
    done

    if ps -p $dpkg_processes -o cmd --no-headers 2>/dev/null | grep -qi "unattended"; then
        echo -e "\e[34m   This is the automatic security updater. It runs after every boot\e[0m"
        echo -e "\e[34m   and finishing on its own is the correct outcome. Waiting.\e[0m"
    fi

    echo -e "\e[34m🕐 Waiting up to $((wait_timeout / 60)) minutes...\e[0m"
    while [ -n "$dpkg_processes" ] && [ "$elapsed" -lt "$wait_timeout" ]; do
        echo -n "."
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
        # A minute marker, so a long wait looks like progress rather than a hang
        [ $(( elapsed % 60 )) -eq 0 ] && echo -n " ${elapsed}s "
        dpkg_processes=$(find_dpkg_processes)
    done
    echo

    if [ -n "$dpkg_processes" ]; then
        echo -e "\e[31m❌ dpkg lock still held after ${wait_timeout}s: $dpkg_processes\e[0m"
        echo -e "\e[31m❌ Not force-killing a live package manager — that corrupts package state.\e[0m"
        echo ""
        echo -e "\e[33m   Stop it cleanly, then run the installer again:\e[0m"
        echo -e "\e[33m     sudo systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service\e[0m"
        echo -e "\e[33m     sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer\e[0m"
        echo ""
        echo -e "\e[33m   Or wait longer: sudo env DPKG_WAIT_TIMEOUT=1800 $0\e[0m"
        exit 1
    fi
    echo -e "\e[32m✅ Lock holder(s) exited on their own after ${elapsed}s\e[0m"
else
    echo -e "\e[32m✅ No active processes found\e[0m"
fi

# Step 2: Remove lock files — safe now that no process holds them.
echo -e "\e[34m🔄 Removing stale dpkg lock files...\e[0m"

lock_files=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock")
lock_files_removed=0
for lock_file in "${lock_files[@]}"; do
    if [ -f "$lock_file" ]; then
        run_privileged rm -f "$lock_file"
        ((lock_files_removed++))
    fi
done

if [ $lock_files_removed -gt 0 ]; then
    echo -e "\e[32m✅ Removed $lock_files_removed stale lock files\e[0m"
else
    echo -e "\e[32m✅ No lock files found\e[0m"
fi

# Step 3: Clean package cache
echo -e "\e[34m🔄 Cleaning package cache...\e[0m"
clean_package_cache
echo -e "\e[32m✅ Package cache cleaned\e[0m"

fi  # end lock-specific steps

# Step 4: Configure dpkg (irreversible transaction — watched, never killed)
if run_watched "🔄 Configuring dpkg (will not be interrupted)..." run_privileged dpkg --configure -a; then
    echo -e "\e[32m✅ dpkg configured\e[0m"
else
    echo -e "\e[31m❌ dpkg configuration failed\e[0m"
fi

# Step 5: Fix broken dependencies (irreversible transaction — watched, never killed)
if run_watched "🔄 Fixing dependencies (will not be interrupted)..." run_privileged apt-get install -f -qq; then
    echo -e "\e[32m✅ Dependencies fixed\e[0m"
else
    echo -e "\e[31m❌ Dependency fix failed\e[0m"
fi

# Step 6: Test if fix worked (lock gone AND nothing left half-configured)
echo -e "\e[34m🔄 Testing fix...\e[0m"
if [ "$(check_dpkg_lock)" = "false" ] && [ -z "$("${audit_cmd[@]}" 2>/dev/null)" ]; then
    echo -e "\e[32m🎉 Success! dpkg state healthy\e[0m"
    exit 0
else
    echo -e "\e[31m❌ dpkg issues persist\e[0m"
    exit 1
fi
