#!/bin/bash

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
# it — these are irreversible package transactions that must not be killed
run_watched() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" >/dev/null 2>&1 &
    local watch_pid=$!
    while kill -0 "$watch_pid" 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo
    wait "$watch_pid"
    return $?
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
wait_timeout=120
wait_interval=2
elapsed=0
dpkg_processes=$(find_dpkg_processes)

if [ -n "$dpkg_processes" ]; then
    echo -e "\e[33m📋 Found processes holding the lock: $dpkg_processes\e[0m"
    while [ -n "$dpkg_processes" ] && [ "$elapsed" -lt "$wait_timeout" ]; do
        echo -n "."
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
        dpkg_processes=$(find_dpkg_processes)
    done
    echo

    if [ -n "$dpkg_processes" ]; then
        echo -e "\e[31m❌ dpkg lock still held after ${wait_timeout}s: $dpkg_processes\e[0m"
        echo -e "\e[31m❌ Not force-killing a live package manager — aborting\e[0m"
        exit 1
    fi
    echo -e "\e[32m✅ Lock holder(s) exited on their own\e[0m"
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