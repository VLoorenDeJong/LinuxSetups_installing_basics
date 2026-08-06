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

print_header "Setting up .NET (ASP.NET Core runtime)"

# =============================================================================
# WHAT THIS INSTALLS, AND WHY ONLY THE RUNTIME BY DEFAULT
# =============================================================================
# The common server case is running applications that were published
# elsewhere and copied onto the machine ("dotnet MyApp.dll", usually behind a
# reverse proxy). That needs the ASP.NET Core runtime only. The SDK is a much
# larger download and is dead weight unless the box compiles its own code,
# which matters on small ARM boards.
#
# To install the SDK instead:
#     sudo env INSTALL_DOTNET_SDK=1 ./add_dotnet.sh
# "sudo env VAR=1" is the only policy-independent way to pass a one-off
# variable through sudo — a bare "VAR=1 sudo ..." is stripped by env_reset.
#
# Packages come from the distro first. That keeps the install free of any
# third-party keyring, and avoids the "pipe a remote install script straight
# into root" pattern that .NET-on-ARM guides tend to recommend.
# =============================================================================

# Minimum acceptable .NET major version. .NET 7 reached end-of-life in
# May 2024 and receives no security patches, so 8 is the floor.
REQUIRED_DOTNET_VERSION=8

INSTALL_DOTNET_SDK="${INSTALL_DOTNET_SDK:-0}"

# Which majors are LTS, and are still supported.
#
# Authoritative list from Microsoft's own release metadata when reachable, the
# same shape add_java.sh uses for the Adoptium API. Falling back to the cadence
# formula (even majors are LTS) when offline, so the script keeps working
# without network access.
#
# The formula alone was not enough: it says .NET 6 is LTS, which is true and
# useless, because support ended in November 2024. The API carries a
# support-phase per channel, so an end-of-life LTS can be left off the list
# instead of being offered as a sensible choice.
DOTNET_RELEASES_URL="https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"
DOTNET_LTS_LIST=""

load_dotnet_lts_list() {
    [ -n "$DOTNET_LTS_LIST" ] && return 0
    command -v curl >/dev/null 2>&1 || return 1

    # Each channel is an object holding channel-version, release-type and
    # support-phase. Flatten to one line, split per channel, and keep the major
    # of any channel that is lts and not eol.
    DOTNET_LTS_LIST="$(curl -fsSL --max-time 10 "$DOTNET_RELEASES_URL" 2>/dev/null \
        | tr -d ' \n\r\t' \
        | tr '{' '\n' \
        | grep '"release-type":"lts"' \
        | grep -v '"support-phase":"eol"' \
        | grep -oE '"channel-version":"[0-9]+' \
        | grep -oE '[0-9]+$')"

    [ -n "$DOTNET_LTS_LIST" ]
}

is_lts_version() {
    local v="$1"
    if load_dotnet_lts_list; then
        printf '%s\n' "$DOTNET_LTS_LIST" | grep -qx "$v"
    else
        # Offline fallback: LTS releases are the even-numbered majors.
        [ $(( v % 2 )) -eq 0 ]
    fi
}

# Enumerate every aspnetcore-runtime-N.0 package apt offers and pick the
# newest LTS major among them.
get_latest_dotnet_lts() {
    local list_cmd="apt-cache pkgnames aspnetcore-runtime-"
    if $TIMEOUT_AVAILABLE; then
        list_cmd="timeout 10 $list_cmd"
    fi

    local best=""
    local v
    while read -r v; do
        [ -n "$v" ] || continue
        if is_lts_version "$v"; then
            if [ -z "$best" ] || [ "$v" -gt "$best" ]; then
                best="$v"
            fi
        fi
    done < <(eval "$list_cmd" 2>/dev/null \
        | grep -E '^aspnetcore-runtime-[0-9]+\.[0-9]+$' \
        | sed -E 's/^aspnetcore-runtime-([0-9]+)\..*$/\1/')

    echo "$best"
}

# Major version of the ASP.NET Core runtime already present, if any
get_installed_aspnet_major() {
    if ! command -v dotnet &> /dev/null; then
        return
    fi
    dotnet --list-runtimes 2>/dev/null \
        | grep '^Microsoft.AspNetCore.App' \
        | awk '{print $2}' \
        | cut -d. -f1 \
        | sort -n | tail -1
}

# -----------------------------------------------------------------------------
# WHICH MAJOR VERSIONS, AND WHY THAT IS A QUESTION
#
# .NET does not roll forward across a major version. An application published
# for net8.0 on a machine that has only runtime 10 does not start, and says so
# in a way that is easy to misread:
#
#   The framework 'Microsoft.AspNetCore.App', version '8.0.0' was not found
#
# Installing "the newest" is therefore wrong whenever the applications are older
# than the newest, which on a server is most of the time. Majors install side by
# side, so the right answer is usually "the one my applications target", and
# sometimes several.
#
# DOTNET_VERSIONS answers it without a prompt:
#
#   sudo env DOTNET_VERSIONS=8 ./add_dotnet.sh
#   sudo env DOTNET_VERSIONS=8,10 ./add_dotnet.sh
#
# Unset and with a terminal, it asks. Unset with no terminal, it keeps the old
# behaviour and takes the newest LTS, because an unattended run must not hang.
# -----------------------------------------------------------------------------
choose_dotnet_versions() {
    local available=() v answer
    while read -r v; do
        [ -n "$v" ] || continue
        is_lts_version "$v" && [ "$v" -ge "$REQUIRED_DOTNET_VERSION" ] 2>/dev/null && available+=("$v")
    done < <(apt-cache pkgnames aspnetcore-runtime- 2>/dev/null \
        | grep -E '^aspnetcore-runtime-[0-9]+\.[0-9]+$' \
        | sed -E 's/^aspnetcore-runtime-([0-9]+)\..*$/\1/' | sort -un)

    # Nothing to choose from means the distro has no supported LTS at all. The
    # Microsoft repository below fixes that, so fall back to the floor.
    if [ ${#available[@]} -eq 0 ]; then
        echo "$REQUIRED_DOTNET_VERSION"
        return
    fi

    if [ ! -r /dev/tty ]; then
        get_latest_dotnet_lts
        return
    fi

    local last=$(( ${#available[@]} ))
    {
        echo ""
        echo -e "\e[36m=== .NET version ===\e[0m"
        echo "Applications only run on the major version they were built for."
        echo "Majors install side by side, so picking several is fine."
        echo ""
        local i=1
        for v in "${available[@]}"; do
            printf "   %d) .NET %s  (LTS)\n" "$i" "$v"
            i=$(( i + 1 ))
        done
        echo ""
        printf "\e[34mWhich do you need? Numbers, comma separated. Enter for %d (.NET %s): \e[0m" \
            "$last" "${available[-1]}"
    } >&2

    read -r answer < /dev/tty || answer=""
    answer="$(echo "$answer" | xargs)"
    [ -z "$answer" ] && answer="$last"

    # Numbers are what the list offers, so numbers are what is read. A value
    # that is not a valid position but IS one of the versions on offer is taken
    # as that version: with ".NET 8" on the screen, typing 8 is a reasonable
    # thing to do and refusing it would be pedantry.
    local picked=() token v
    for token in $(echo "$answer" | tr ',' ' '); do
        if [ "$token" -ge 1 ] 2>/dev/null && [ "$token" -le "$last" ] 2>/dev/null; then
            picked+=("${available[$(( token - 1 ))]}")
            continue
        fi
        for v in "${available[@]}"; do
            [ "$token" = "$v" ] && picked+=("$v") && continue 2
        done
        printf "\e[31m❌ '%s' is not on the list. Pick 1 to %d.\e[0m\n" "$token" "$last" >&2
        return 1
    done

    printf '%s\n' "${picked[@]}" | sort -un | tr '\n' ' ' | xargs
}

# --- Which majors do we want, and which are already here? --------------------
check_and_fix_dpkg_lock

if ! show_progress "📦 Updating package lists" "sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
    print_error "Failed to update package lists"
    exit 1
fi

if [ -n "${DOTNET_VERSIONS:-}" ]; then
    read -r -a WANTED <<< "$(echo "$DOTNET_VERSIONS" | tr ',' ' ' | xargs)"
else
    read -r -a WANTED <<< "$(choose_dotnet_versions)"
fi

if [ ${#WANTED[@]} -eq 0 ]; then
    print_error "No .NET version chosen, so there is nothing to install."
    print_warning "Pass one explicitly: sudo env DOTNET_VERSIONS=8 $0"
    exit 1
fi

# Checked per major rather than "is anything new enough installed". The old
# check passed as soon as any runtime at or above the floor existed, so a
# machine with only 10 looked satisfied while its net8.0 applications could not
# start.
MISSING=()
for v in "${WANTED[@]}"; do
    if ! echo "$v" | grep -qE '^[0-9]+$'; then
        print_error "'$v' is not a major version number."
        print_warning "Use whole numbers: DOTNET_VERSIONS=8,10"
        exit 1
    fi
    # The SDK is a separate package, so "the runtime is here" does not answer the
    # question when the SDK was asked for. Checking only runtimes meant a box
    # with runtime 10 already present reported itself satisfied and never
    # installed the SDK it had been told to install.
    have_runtime=false
    have_sdk=false
    dotnet --list-runtimes 2>/dev/null | grep -q "^Microsoft.AspNetCore.App ${v}\." && have_runtime=true
    dotnet --list-sdks     2>/dev/null | grep -q "^${v}\."                          && have_sdk=true

    if [ "$INSTALL_DOTNET_SDK" = "1" ]; then
        if $have_sdk; then
            print_success ".NET SDK $v is already installed"
        else
            MISSING+=("$v")
        fi
    elif $have_runtime; then
        print_success "ASP.NET Core runtime $v is already installed"
    else
        MISSING+=("$v")
    fi
done

NEED_INSTALL=false
[ ${#MISSING[@]} -gt 0 ] && NEED_INSTALL=true

if $NEED_INSTALL; then
    print_status "Preparing to install .NET ${MISSING[*]}..."

    # Does the distro offer every major we still need?
    DISTRO_HAS_ALL=true
    for v in "${MISSING[@]}"; do
        apt-cache pkgnames aspnetcore-runtime- 2>/dev/null \
            | grep -qx "aspnetcore-runtime-${v}.0" || DISTRO_HAS_ALL=false
    done

    # If not, fall back to Microsoft's own feed — same escalation shape
    # add_java.sh uses for Adoptium.
    if ! $DISTRO_HAS_ALL; then
        print_warning "Not every requested version is in the distro — adding the packages.microsoft.com repository"

        . /etc/os-release
        sudo mkdir -p /etc/apt/keyrings
        if ! curl -fsSL --max-time 30 https://packages.microsoft.com/keys/microsoft.asc \
            | sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg 2>/dev/null; then
            print_error "Could not download the Microsoft signing key — check network access"
            exit 1
        fi

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${VERSION_CODENAME} main" \
            | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null

        # Ubuntu ships its own dotnet packages, and having both feeds active
        # for the same package names is a documented breakage. Pin the dotnet
        # package names to Microsoft's origin so apt cannot mix the two.
        sudo tee /etc/apt/preferences.d/99-microsoft-dotnet.pref >/dev/null <<'EOF'
Package: dotnet* aspnet* netstandard*
Pin: origin "packages.microsoft.com"
Pin-Priority: 1001
EOF

        if ! show_progress "📦 Updating package lists (Microsoft)" "sudo apt-get update -qq >/dev/null 2>&1" 2 180; then
            print_error "Failed to update package lists after adding the Microsoft repository"
            exit 1
        fi

    fi

    # One apt transaction for every missing major. Separate calls would leave a
    # machine with half of what was asked for if the second one failed.
    DOTNET_PACKAGES=()
    for v in "${MISSING[@]}"; do
        if [ "$INSTALL_DOTNET_SDK" = "1" ]; then
            DOTNET_PACKAGES+=("dotnet-sdk-${v}.0")
        else
            DOTNET_PACKAGES+=("aspnetcore-runtime-${v}.0")
        fi
    done

    if [ "$INSTALL_DOTNET_SDK" = "1" ]; then
        print_status "INSTALL_DOTNET_SDK=1 — installing the full SDK instead of the runtime"
    fi

    # Irreversible dpkg transaction: watch-only, never killed, and the apt
    # output is logged so a failure shows WHY instead of a bare exit code
    DOTNET_APT_LOG="/tmp/add_dotnet_apt.log"
    if ! show_progress_bar_watch_only "🌐 Installing ${DOTNET_PACKAGES[*]} (will not be interrupted)" "$DOTNET_APT_LOG" \
        bash -c "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends ${DOTNET_PACKAGES[*]} >$DOTNET_APT_LOG 2>&1"; then
        print_error "Failed to install ${DOTNET_PACKAGES[*]} — apt output:"
        tail -20 "$DOTNET_APT_LOG" 2>/dev/null || true
        print_error "Full log: $DOTNET_APT_LOG"
        exit 1
    fi

    print_success ".NET packages installed successfully"
fi

# --- Configure the .NET environment ------------------------------------------
print_status "Configuring the .NET environment..."

# Opt out of the CLI telemetry ping on an unattended server. Set once in
# /etc/environment so service units inherit it too.
if ! grep -q "DOTNET_CLI_TELEMETRY_OPTOUT" /etc/environment 2>/dev/null; then
    echo 'DOTNET_CLI_TELEMETRY_OPTOUT="1"' | sudo tee -a /etc/environment > /dev/null
    print_success "DOTNET_CLI_TELEMETRY_OPTOUT set"
fi

# --- Verify ------------------------------------------------------------------
print_status "Verifying the .NET installation..."

if ! command -v dotnet &> /dev/null; then
    print_error ".NET verification failed — the dotnet binary is not on PATH"
    exit 1
fi

# Web applications need the ASP.NET Core shared framework specifically, not
# just the base runtime — check for that rather than for "dotnet exists"
if ! dotnet --list-runtimes 2>/dev/null | grep -q '^Microsoft.AspNetCore.App'; then
    print_error "The ASP.NET Core shared framework is missing — web application services will not start"
    print_error "Installed runtimes:"
    dotnet --list-runtimes 2>/dev/null || true
    exit 1
fi

FINAL_MAJOR="$(get_installed_aspnet_major)"
if [ -n "$FINAL_MAJOR" ] && [ "$FINAL_MAJOR" -lt "$REQUIRED_DOTNET_VERSION" ] 2>/dev/null; then
    print_error "ASP.NET Core runtime is $FINAL_MAJOR, which is below the required $REQUIRED_DOTNET_VERSION"
    exit 1
fi

# Every major that was asked for, not just the newest one present. Checking only
# the newest is how a machine ends up looking correct while the applications
# that need an older major cannot start.
STILL_MISSING=()
for v in ${WANTED+"${WANTED[@]}"}; do
    if [ "$INSTALL_DOTNET_SDK" = "1" ]; then
        dotnet --list-sdks 2>/dev/null | grep -q "^${v}\." || STILL_MISSING+=("$v")
    else
        dotnet --list-runtimes 2>/dev/null | grep -q "^Microsoft.AspNetCore.App ${v}\." \
            || STILL_MISSING+=("$v")
    fi
done
if [ ${#STILL_MISSING[@]} -gt 0 ]; then
    print_error "Asked for but not installed: ${STILL_MISSING[*]}"
    print_error "Applications built for those majors will not start."
    print_error "Installed runtimes:"
    dotnet --list-runtimes 2>/dev/null | grep '^Microsoft.AspNetCore.App' || true
    exit 1
fi

print_success ".NET installation and configuration complete"
echo -e "\e[34m📊 SDK/Runtime: \e[0m$(dotnet --version 2>/dev/null || echo 'runtime-only install (no SDK)')"
echo -e "\e[34m🌐 ASP.NET Core: \e[0m"
dotnet --list-runtimes 2>/dev/null | grep '^Microsoft.AspNetCore.App' | awk '{print "   " $2}' || true
