#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
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

# Watch-only progress for irreversible package transactions: shows dots but
# never kills the command — a SIGKILL mid-dpkg can corrupt package state
show_progress_watch_only() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local watch_pid=$!
    while kill -0 "$watch_pid" 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep 3 || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done
    echo
    wait "$watch_pid"
    return $?
}

# Watch-only spinner + progress bar: never kills the wrapped command (same
# regime as show_progress_watch_only), but renders a live bar from apt's
# machine-readable status lines ("pmstatus:...:PCT:desc" / "dlstatus:...")
# that land in the log when apt-get runs with -o APT::Status-Fd=1.
show_progress_bar_watch_only() {
    local message="$1"
    local logfile="$2"
    shift 2

    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local width=28
    local empty_bar full_bar
    empty_bar=$(printf '░%.0s' $(seq 1 $width))
    full_bar=$(printf '█%.0s' $(seq 1 $width))

    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local cmd_pid=$!
    local tick=0

    while kill -0 "$cmd_pid" 2>/dev/null; do
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

    wait "$cmd_pid"
    local exit_code=$?
    printf '\r\033[K'  # Clear the bar line before normal output resumes
    return $exit_code
}

# Check if timeout command is available
if ! command -v timeout &> /dev/null; then
    echo -e "\e[33m⚠️  timeout command not available, using direct commands\e[0m"
    TIMEOUT_AVAILABLE=false
else
    TIMEOUT_AVAILABLE=true
fi

# Function to check for DPKG lock issues (calls the dedicated script)
check_and_fix_dpkg_lock() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fix_script="$script_dir/fix_dpkg_lock.sh"
    if [ ! -f "$fix_script" ]; then
        # The shared basics layer (submodule) holds fix_dpkg_lock.sh
        fix_script="$script_dir/../../${BASICS_SUBMODULE:-LinuxBasics}/install_scripts/fix_dpkg_lock.sh"
    fi
    
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

print_header "Setting up Certbot (Let's Encrypt)"

# =============================================================================
# THIS INSTALLS CERTBOT. IT DOES NOT REQUEST ANY CERTIFICATES.
# =============================================================================
# Asking for certificates is per-site work: it needs the Apache virtual hosts
# to already exist and resolve publicly, and it edits those vhosts in place.
# That belongs with the machine's own site config, not in a shared installer.
#
# Let's Encrypt also rate-limits failed validations (60 per hour per account),
# and a burnt limit locks you out of certifying for the rest of the hour. A
# generic installer that tried to certify would spend that budget on hosts
# that were never ready.
#
# Once the sites are up, request the certificates by hand:
#     sudo certbot --apache --test-cert     # rehearsal, does not count as real
#     sudo certbot --apache                 # the real thing
# =============================================================================

CERTBOT_PACKAGES=(certbot python3-certbot-apache)

if command -v certbot &> /dev/null; then
    print_success "Certbot is already installed: $(certbot --version 2>&1 | head -n 1)"
else
    print_status "Preparing to install Certbot..."

    check_and_fix_dpkg_lock

    if ! show_progress "📦 Updating package lists" "sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
        print_error "Failed to update package lists"
        exit 1
    fi

    # Irreversible dpkg transaction: watch-only, never killed, and the apt
    # output is logged so a failure shows WHY instead of a bare exit code
    CERTBOT_APT_LOG="/tmp/add_certbot_apt.log"
    if ! show_progress_bar_watch_only "🔐 Installing ${CERTBOT_PACKAGES[*]} (will not be interrupted)" "$CERTBOT_APT_LOG" \
        bash -c "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends ${CERTBOT_PACKAGES[*]} >$CERTBOT_APT_LOG 2>&1"; then
        print_error "Failed to install Certbot — apt output:"
        tail -20 "$CERTBOT_APT_LOG" 2>/dev/null || true
        print_error "Full log: $CERTBOT_APT_LOG"
        exit 1
    fi

    print_success "Certbot installed"
fi

# --- Apache plugin check -----------------------------------------------------
# Without python3-certbot-apache, "certbot --apache" fails at the moment you
# need it most, which is usually long after this script ran.
if ! command -v apache2ctl &> /dev/null; then
    print_warning "Apache is not installed yet — the --apache plugin has nothing to configure"
    print_warning "Run add_apache_webserver.sh before requesting certificates"
fi

# --- Automatic renewal -------------------------------------------------------
# A certificate lasts 90 days. The packaged timer is what stops that becoming
# a yearly outage, so it is verified rather than assumed.
print_status "Checking automatic renewal..."

if systemctl list-unit-files 2>/dev/null | grep -q '^certbot\.timer'; then
    sudo systemctl enable certbot.timer &>/dev/null || true
    sudo systemctl start certbot.timer &>/dev/null || true

    if systemctl is-active --quiet certbot.timer; then
        print_success "certbot.timer is active — certificates renew automatically"
        NEXT_RUN=$(systemctl list-timers certbot.timer --no-pager 2>/dev/null | awk 'NR==2 {print $1, $2, $3}')
        if [ -n "$NEXT_RUN" ]; then
            echo -e "\e[34m⏰ Next renewal check: \e[0m$NEXT_RUN"
        fi
    else
        print_warning "certbot.timer did not start — renewals will not happen on their own"
        print_warning "Check: systemctl status certbot.timer"
    fi
else
    print_warning "No certbot.timer on this system — check how renewal is scheduled here"
fi

# --- Verify ------------------------------------------------------------------
if ! command -v certbot &> /dev/null; then
    print_error "Certbot verification failed — the certbot binary is not on PATH"
    exit 1
fi

print_success "Certbot installation complete"
echo -e "\e[34m📊 Version: \e[0m$(certbot --version 2>&1 | head -n 1)"
echo -e "\e[34m📁 Certificates: \e[0m/etc/letsencrypt/live/  (none yet until you request them)"
echo -e "\e[34m▶️  Next step: \e[0msudo certbot --apache --test-cert   (rehearsal first)"
