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
# Restore Ubuntu's standard dynamic MOTD (login banner) — system load, disk/
# memory/swap usage, temperature, process count, logged-in users, IP
# addresses, pending-updates count, ESM status — and extend it with a few
# health lines stock Ubuntu doesn't surface.
#
# Deliberately kept identical (apart from this header) to the copy in the
# FLSUN_V400 branch, so every server in this fleet shows the same banner
# layout. Nothing in here is project-specific: the custom-banner patterns in
# Step 3 simply match nothing on a stock Ubuntu server, and the WiFi line in
# Step 4 is skipped when nmcli isn't installed.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️  %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# Inline show_progress function (always used)
show_progress() {
    local message="$1"
    local command="$2"
    local interval="${3:-5}"
    local timeout="${4:-600}"
    local log_file
    log_file=$(mktemp /tmp/progress.XXXXXX.log)
    printf "\033[34m%s\033[0m\n" "$message"

    # Debug mode: stream output live. No dots, no kill timer.
    if [ "${MOTD_DEBUG:-0}" = "1" ]; then
        eval "$command" 2>&1 | tee "$log_file"
        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -eq 0 ]; then
            rm -f "$log_file"
        else
            printf "\033[31m❌ Command failed (exit %s). Full log: %s\033[0m\n" "$exit_code" "$log_file"
        fi
        return "$exit_code"
    fi

    # Normal mode: capture output to the log. Show dots.
    eval "$command" >"$log_file" 2>&1 &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)
    while kill -0 $cmd_pid 2>/dev/null; do
        printf "."
        sleep "$interval"
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            printf "\n\033[31m❌ Command timed out after %d seconds\033[0m\n" "$timeout"
            kill -TERM $cmd_pid 2>/dev/null || true
            sleep 2
            kill -KILL $cmd_pid 2>/dev/null || true
            printf "\033[31mLast output before timeout:\033[0m\n"
            tail -n 20 "$log_file"
            printf "\033[33mFull log: %s\033[0m\n" "$log_file"
            return 1
        fi
    done
    wait $cmd_pid 2>/dev/null
    local exit_code=$?
    printf "\n"
    if [ "$exit_code" -ne 0 ]; then
        printf "\033[31m❌ Command failed (exit %s). Last output:\033[0m\n" "$exit_code"
        tail -n 20 "$log_file"
        printf "\033[33mFull log: %s\033[0m\n" "$log_file"
    else
        rm -f "$log_file"
    fi
    return "$exit_code"
}

# Check and fix any DPKG locks before proceeding with package operations.
# fix_dpkg_lock.sh lives in the LinuxBasics submodule on this branch, not
# alongside this script, so both locations are checked.
check_and_fix_dpkg_lock() {
    local script_dir fix_script candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fix_script=""
    for candidate in \
        "$script_dir/fix_dpkg_lock.sh" \
        "$script_dir/../../LinuxBasics/install_scripts/fix_dpkg_lock.sh"; do
        if [ -f "$candidate" ]; then
            fix_script="$candidate"
            break
        fi
    done
    if [ -n "$fix_script" ]; then
        print_status "Checking and fixing DPKG locks..."
        bash "$fix_script" || print_warning "DPKG lock fix failed, continuing anyway..."
    else
        print_warning "fix_dpkg_lock.sh not found, proceeding without DPKG lock check"
    fi
}

if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must run with sudo/root privileges."
    exit 1
fi

STATE_DIR="/var/lib/linuxbasics"
STATE_FILE="${STATE_DIR}/configure_motd_services.done"
FORCE_RUN="${FORCE_RUN_MOTD:-0}"

if [ -f "$STATE_FILE" ] && [ "$FORCE_RUN" != "1" ]; then
    print_warning "Default MOTD already restored previously. Skipping."
    print_warning "To force rerun: sudo env FORCE_RUN_MOTD=1 bash $0"
    exit 0
fi

print_header "Restore Default Ubuntu Dynamic MOTD"

# --- Step 1: install the packages that generate the standard dynamic blocks ---
# landscape-common provides /etc/update-motd.d/50-landscape-sysinfo (load,
# disk/memory/swap, temperature, processes, logged-in users, IP addresses).
# update-notifier-common provides the updates-available / ESM / release-
# upgrade blocks.
NEEDED_PKGS=()
for pkg in landscape-common update-notifier-common; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        NEEDED_PKGS+=("$pkg")
    fi
done

if [ ${#NEEDED_PKGS[@]} -gt 0 ]; then
    check_and_fix_dpkg_lock
    show_progress "📦 Updating package lists" "apt-get update -qq" 3 300
    show_progress "📦 Installing ${NEEDED_PKGS[*]}" \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${NEEDED_PKGS[*]}" 3 300
    print_success "Installed: ${NEEDED_PKGS[*]}"
else
    print_success "landscape-common and update-notifier-common already installed"
fi

# --- Step 2: make sure the standard update-motd.d scripts are executable ---
MOTD_DIR="/etc/update-motd.d"
if [ -d "$MOTD_DIR" ]; then
    print_status "Ensuring update-motd.d scripts are executable..."
    chmod +x "$MOTD_DIR"/* 2>/dev/null || true
    print_success "update-motd.d scripts are executable"
else
    print_warning "$MOTD_DIR not found — dynamic MOTD scripts are not installed on this system."
fi

# --- Step 3: detect and neutralize a custom static/branded banner ---
# Vendor images sometimes inject a custom credit line (e.g. "By <name>
# Running on ...") in place of the standard dynamic blocks. Kept as an array
# (not a single regex) so another vendor's custom-banner style can be added
# as one extra line here, rather than restructuring this section. Scans
# /etc/motd and every update-motd.d script; disables (never deletes) anything
# found — renamed with a .disabled-by-configure-motd-services suffix so it
# stays fully reversible. On a stock Ubuntu server this matches nothing.
CUSTOM_BANNER_PATTERNS=(
    '[Bb]y [A-Za-z0-9_]+ [Rr]unning on'   # FLSUN stock image credit line
    # Add more patterns here for other vendors' custom banners as encountered.
)

matches_any_banner_pattern() {
    local file="$1" pattern
    for pattern in "${CUSTOM_BANNER_PATTERNS[@]}"; do
        grep -qE "$pattern" "$file" 2>/dev/null && return 0
    done
    return 1
}

strip_banner_lines() {
    local file="$1" grep_args=()
    for pattern in "${CUSTOM_BANNER_PATTERNS[@]}"; do
        grep_args+=(-e "$pattern")
    done
    grep -vE "${grep_args[@]}" "$file"
}

FOUND_CUSTOM=0

if [ -f /etc/motd ] && matches_any_banner_pattern /etc/motd; then
    print_warning "Custom branded line found in /etc/motd — backing up and clearing it."
    cp /etc/motd "/etc/motd.bak-$(date +%Y%m%dT%H%M%S)"
    strip_banner_lines /etc/motd > /etc/motd.tmp && mv /etc/motd.tmp /etc/motd
    FOUND_CUSTOM=1
fi

if [ -d "$MOTD_DIR" ]; then
    while IFS= read -r -d '' script; do
        if matches_any_banner_pattern "$script"; then
            print_warning "Custom branded update-motd.d script found: $script — disabling."
            mv "$script" "${script}.disabled-by-configure-motd-services"
            FOUND_CUSTOM=1
        fi
    done < <(find "$MOTD_DIR" -maxdepth 1 -type f -print0)
fi

if [ "$FOUND_CUSTOM" -eq 1 ]; then
    print_success "Custom branding neutralized (originals backed up, not deleted)."
else
    print_status "No custom branded banner text detected — nothing to neutralize."
fi

# --- Step 4: install extra health/status lines not already covered by stock Ubuntu ---
# reboot-required and updates-available/ESM are already handled by
# update-notifier-common (installed in Step 1) — do NOT duplicate those here.
# This only adds what stock Ubuntu doesn't already surface: failed systemd
# units, uptime, root inode usage, and WiFi signal quality.
EXTRAS_SCRIPT="$MOTD_DIR/60-guiderails-extras"
if [ -d "$MOTD_DIR" ]; then
    print_status "Installing additional status line (failed units, uptime, inodes, WiFi signal)..."
    cat > "$EXTRAS_SCRIPT" <<'MOTD_EXTRAS_EOF'
#!/bin/sh
# Generic health/status additions to the dynamic MOTD.
# Deliberately dependency-free (systemctl/uptime/df/nmcli only — no jq/curl)
# and deliberately does NOT duplicate reboot-required or updates-available,
# which stock Ubuntu's update-notifier-common already provides.

FAILED_UNITS="$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')"
if [ -n "$FAILED_UNITS" ]; then
    printf "\n⚠️  Failed units: %s\n" "$(echo "$FAILED_UNITS" | tr '\n' ' ')"
fi

UPTIME_STR="$(uptime -p 2>/dev/null | sed 's/^up //')"
[ -n "$UPTIME_STR" ] && printf "  Uptime:                %s\n" "$UPTIME_STR"

INODE_LINE="$(df -i / 2>/dev/null | awk 'NR==2 {print $5" ("$3" of "$2" inodes used)"}')"
[ -n "$INODE_LINE" ] && printf "  Inode usage of /:      %s\n" "$INODE_LINE"

if command -v nmcli >/dev/null 2>&1; then
    WIFI_IFACE="$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    if [ -n "$WIFI_IFACE" ]; then
        SIGNAL="$(nmcli -t -f IN-USE,SIGNAL dev wifi 2>/dev/null | awk -F: '$1=="*"{print $2; exit}')"
        [ -n "$SIGNAL" ] && printf "  WiFi signal (%s):      %s%%\n" "$WIFI_IFACE" "$SIGNAL"
    fi
fi

# Optional, project-specific: if a services list has been installed alongside
# this generic script (one systemd unit name per line), show each one's
# status. Entirely skipped if the file doesn't exist, so this stays
# domain-neutral — no project's service names are hardcoded here.
SERVICES_LIST="$(dirname "$0")/services.list"
if [ -f "$SERVICES_LIST" ]; then
    printf "\n  Services:\n"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        # Literal UTF-8 marks: dash's printf has no \x escapes.
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            printf "    %-16s ● active\n" "$svc"
        else
            # is-active prints the state AND exits non-zero, so capture
            # first; only an empty result means the unit is unknown.
            state="$(systemctl is-active "$svc" 2>/dev/null)"
            [ -n "$state" ] || state="not found"
            printf "    %-16s ✗ %s\n" "$svc" "$state"
        fi
    done < "$SERVICES_LIST"
fi
MOTD_EXTRAS_EOF
    chmod +x "$EXTRAS_SCRIPT"
    print_success "Installed: $EXTRAS_SCRIPT"

    if grep -rlq "reboot-required" "$MOTD_DIR"/9[0-9]-* 2>/dev/null; then
        print_status "Reboot-required is already handled by an existing update-motd.d script — not duplicated."
    fi
fi

# --- Step 5: verify (never modify) PAM is set up to display the dynamic MOTD ---
# Editing /etc/pam.d/sshd automatically is too risky on a headless server — a
# malformed PAM config can break SSH login entirely, with no physical console
# to recover from. Detect and report only; never auto-edit this file.
if [ -f /etc/pam.d/sshd ]; then
    if grep -q "pam_motd.so.*motd=/run/motd.dynamic" /etc/pam.d/sshd && \
       grep -q "pam_motd.so.*noupdate" /etc/pam.d/sshd; then
        print_success "PAM sshd config already set up for dynamic MOTD."
    else
        print_warning "PAM sshd config is missing the standard dynamic-MOTD lines."
        print_warning "This script will NOT edit /etc/pam.d/sshd automatically — a mistake there"
        print_warning "can break SSH login with no physical console to recover from."
        print_warning "If the banner still looks wrong after reconnecting, add these two lines to"
        print_warning "/etc/pam.d/sshd yourself (in the 'session' block), then test in a NEW SSH"
        print_warning "session before closing your current one:"
        echo "    session    optional     pam_motd.so  motd=/run/motd.dynamic"
        echo "    session    optional     pam_motd.so  noupdate"
    fi
else
    print_warning "/etc/pam.d/sshd not found — cannot verify dynamic MOTD is wired up."
fi

# --- Step 6: regenerate the cached dynamic MOTD now, so it's correct on next login ---
if [ -d "$MOTD_DIR" ]; then
    print_status "Regenerating cached dynamic MOTD..."
    if run-parts "$MOTD_DIR" > /run/motd.dynamic 2>/dev/null; then
        print_success "Regenerated /run/motd.dynamic"
    else
        print_warning "Could not regenerate /run/motd.dynamic — it will refresh on next login/timer run anyway."
    fi
fi

mkdir -p "$STATE_DIR"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STATE_FILE"

print_success "Default MOTD restoration complete. Reconnect via SSH to see the new banner."
