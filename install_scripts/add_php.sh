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

print_header "Setting up PHP (PHP-FPM behind Apache)"

# =============================================================================
# WHY PHP-FPM AND NOT mod_php
# =============================================================================
# libapache2-mod-php only runs under the mpm_prefork MPM, so installing it
# silently switches Apache off mpm_event. On any host where Apache also
# reverse-proxies to application servers, prefork is the wrong MPM: it costs a
# whole process per connection. php-fpm keeps Apache on mpm_event and runs PHP
# in its own pool, which is also the layout Ubuntu documents.
#
# The distro's DEFAULT PHP version is used deliberately, never "the newest
# available": it is what this release ships, tests against and patches, and it
# needs no version pin to maintain.
# =============================================================================

# Install php-fpm and php-cli explicitly rather than the "php" metapackage.
# "php" depends on "libapache2-mod-php | phpX.Y-fpm | phpX.Y-cgi" and apt
# satisfies that with the FIRST alternative — i.e. it would drag in mod_php
# and flip the MPM, which is exactly what this script avoids.
PHP_PACKAGES=(php-fpm php-cli)

check_php_installation() {
    if command -v php &> /dev/null; then
        local php_version
        php_version=$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "unknown")
        print_success "PHP is already installed: $php_version"
        return 0
    fi
    return 1
}

# Resolve the installed PHP-FPM version (e.g. "8.3") from the package name.
# The a2enconf snippet and the FPM socket path are both named after it, so it
# is read from dpkg rather than assumed.
get_php_fpm_version() {
    local ver
    ver=$(dpkg-query -W -f='${Package} ${Status}\n' 'php*-fpm' 2>/dev/null \
        | awk '$NF == "installed" {print $1}' \
        | grep -oE '[0-9]+\.[0-9]+' \
        | sort -V | tail -1)

    if [ -z "$ver" ] && command -v php &> /dev/null; then
        # Fallback: ask the interpreter itself
        ver=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
    fi

    echo "$ver"
}

NEED_INSTALL=true
if check_php_installation && dpkg-query -W -f='${Status}' 'php*-fpm' 2>/dev/null | grep -q "install ok installed"; then
    NEED_INSTALL=false
fi

if $NEED_INSTALL; then
    print_status "Preparing to install PHP..."

    # Check and fix DPKG locks before proceeding
    check_and_fix_dpkg_lock

    if ! show_progress "📦 Updating package lists" "sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
        print_error "Failed to update package lists"
        exit 1
    fi

    # Irreversible dpkg transaction: watch-only, never killed, and the apt
    # output is logged so a failure shows WHY instead of a bare exit code
    PHP_APT_LOG="/tmp/add_php_apt.log"
    if ! show_progress_bar_watch_only "🐘 Installing ${PHP_PACKAGES[*]} (will not be interrupted)" "$PHP_APT_LOG" \
        bash -c "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends ${PHP_PACKAGES[*]} >$PHP_APT_LOG 2>&1"; then
        print_error "Failed to install PHP — apt output:"
        tail -20 "$PHP_APT_LOG" 2>/dev/null || true
        print_error "Full log: $PHP_APT_LOG"
        exit 1
    fi

    print_success "PHP packages installed successfully"
fi

PHP_VERSION="$(get_php_fpm_version)"
if [ -z "$PHP_VERSION" ]; then
    print_error "Could not determine the installed PHP-FPM version — cannot wire PHP into Apache"
    print_error "Check: dpkg -l 'php*-fpm'"
    exit 1
fi
print_status "Detected PHP-FPM version: $PHP_VERSION"

# --- Enable and start the FPM pool -------------------------------------------
FPM_SERVICE="php${PHP_VERSION}-fpm"
print_status "Enabling ${FPM_SERVICE}..."
sudo systemctl enable "$FPM_SERVICE" &>/dev/null || true
if ! sudo systemctl restart "$FPM_SERVICE"; then
    print_error "${FPM_SERVICE} failed to start"
    sudo systemctl status "$FPM_SERVICE" --no-pager -l 2>/dev/null | tail -20 || true
    exit 1
fi
print_success "${FPM_SERVICE} is running"

# --- Wire PHP into Apache ----------------------------------------------------
# Apache is optional here on purpose: this script must not fail when it runs
# before add_apache_webserver.sh, or on a host that only needs the PHP CLI.
if ! command -v apache2ctl &> /dev/null; then
    print_warning "Apache is not installed — skipping the Apache/PHP wiring"
    print_warning "Run add_apache_webserver.sh first, then re-run this script to enable proxy_fcgi"
else
    print_status "Wiring PHP-FPM into Apache..."

    # proxy_fcgi hands .php requests to the FPM pool; setenvif is what the
    # phpX.Y-fpm conf snippet uses to match them
    for mod in proxy_fcgi setenvif; do
        if sudo a2enmod "$mod" 2>&1 | grep -qi "already enabled"; then
            print_status "Apache module $mod already enabled"
        else
            print_success "Apache module $mod enabled"
        fi
    done

    # The conf snippet ships with the phpX.Y-fpm package
    if [ -f "/etc/apache2/conf-available/php${PHP_VERSION}-fpm.conf" ]; then
        sudo a2enconf "php${PHP_VERSION}-fpm" &>/dev/null || true
        print_success "Apache conf php${PHP_VERSION}-fpm enabled"
    else
        print_warning "/etc/apache2/conf-available/php${PHP_VERSION}-fpm.conf not found — PHP files will not be handled by Apache"
    fi

    # Never reload Apache on a broken config: on a host that also proxies
    # application servers, that would take every proxied site down with it
    if sudo apache2ctl configtest 2>&1 | grep -q "Syntax OK"; then
        print_success "Apache config test passed"
        if sudo systemctl reload apache2; then
            print_success "Apache reloaded"
        else
            print_error "Apache reload failed"
            exit 1
        fi
    else
        print_error "Apache config test FAILED — not reloading. Output:"
        sudo apache2ctl configtest 2>&1 | tail -20 || true
        exit 1
    fi
fi

# --- Verify ------------------------------------------------------------------
print_status "Verifying PHP installation..."

if ! command -v php &> /dev/null; then
    print_error "PHP verification failed — the php binary is not on PATH"
    exit 1
fi

FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
if [ -S "$FPM_SOCKET" ]; then
    print_success "FPM socket present: $FPM_SOCKET"
else
    print_warning "FPM socket not found at $FPM_SOCKET — check: systemctl status $FPM_SERVICE"
fi

print_success "PHP installation and configuration complete"
echo -e "\e[34m📊 Version: \e[0m$(php -v 2>/dev/null | head -n 1)"
echo -e "\e[34m🔌 Handler: \e[0m${FPM_SERVICE} (mpm_event preserved, mod_php not installed)"
