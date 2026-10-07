#!/bin/bash
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

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

# Prompts. print_action cannot be one: it ends with a newline.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}"; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only: see the timeout regimes above.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

# The directly connected subnets, as add_smb.sh finds them. SSH_ALLOW_FROM
# (space separated) overrides, for a machine reached through a VPN.
ssh_sources() {
    if [ -n "${SSH_ALLOW_FROM:-}" ]; then
        set -f
        printf '%s\n' $SSH_ALLOW_FROM
        set +f
        return 0
    fi
    { ip -o -4 route show; ip -o -6 route show; } 2>/dev/null \
        | awk '$1 == "default" || / via / || $1 !~ /\// { next }
               { d = ""; for (i = 1; i < NF; i++) if ($i == "dev") d = $(i + 1) }
               d !~ /^(lo|docker|br-|veth|wg)/ { print $1 }' \
        | sort -u
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root."
    print_action "Run: sudo $0"
    exit 1
fi

SSH_LOG="$(mktemp /tmp/add_ssh.XXXXXX.log)"

# Watch-only progress for irreversible package transactions: never kills the
# command, because a SIGKILL mid-dpkg can corrupt package state.
show_progress_watch_only() {
    local message="$1"
    shift
    print_status "$message"
    "$@" >"$SSH_LOG" 2>&1 &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        printf "."
        sleep 3
    done
    echo
    wait "$cmd_pid"
}

if ! dpkg -s openssh-server &> /dev/null; then
    # Package-list update is kill-safe and retryable, so a timeout is fine here.
    spinner_start "Updating the package list"
    if ! timeout 180 apt-get update -qq --fix-missing >"$SSH_LOG" 2>&1; then
        spinner_stop
        print_error "apt-get update failed. Last lines of $SSH_LOG:"
        tail -20 "$SSH_LOG"
        exit 1
    fi
    spinner_stop
    # The install is an irreversible dpkg transaction: never under a kill timeout.
    if show_progress_watch_only "📦 Installing openssh-server" \
        apt-get install -y -qq --no-install-recommends openssh-server; then
        :
    else
        rc=$?
        print_error "Installing openssh-server failed (exit $rc). Last lines of $SSH_LOG:"
        tail -20 "$SSH_LOG"
        exit 1
    fi
fi

# Ubuntu 24.04+ socket-activates sshd (ssh.socket): either unit active is fine.
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet ssh.socket; then
    print_status "Enabling and starting SSH service..."
    if ! { systemctl enable ssh && systemctl start ssh; } >"$SSH_LOG" 2>&1; then
        print_error "Failed to enable or start SSH, output:"
        tail -5 "$SSH_LOG" 2>/dev/null || true
        exit 1
    fi
fi

SSH_LAN_ONLY=0
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    # Port 22 from the LAN only.
    mapfile -t SSH_FROM < <(ssh_sources)
    if [ ${#SSH_FROM[@]} -eq 0 ]; then
        print_error "No local subnet found, so port 22 was left as it is."
        print_action "Name it: sudo env SSH_ALLOW_FROM='192.168.1.0/24' bash $0"
    else
        for src in "${SSH_FROM[@]}"; do
            if ! ufw allow from "$src" to any port 22 proto tcp >"$SSH_LOG" 2>&1; then
                print_error "Failed to allow SSH from $src in UFW, output:"
                tail -5 "$SSH_LOG" 2>/dev/null || true
                exit 1
            fi
        done
        SSH_LAN_ONLY=1
        print_status "SSH allowed from: ${SSH_FROM[*]}"

        # An open-to-everyone rule is reported, never deleted here: under sudo
        # this script cannot tell which session the delete would cut off.
        if ufw status | grep -qE "^(22(/tcp)?|OpenSSH)( \(v6\))? +(ALLOW|LIMIT) +Anywhere"; then
            print_info "Port 22 is still open to everyone by an older rule."
            print_action "From the LAN or the keyboard: sudo ufw delete allow 22/tcp (or OpenSSH)"
        fi
    fi
fi

# Passwords stay on: port 22 is LAN-only above, and the owner logs in with one.
HARDEN="/etc/ssh/sshd_config.d/10-linuxbasics-hardening.conf"
{
    echo "# Written by add_ssh.sh."
    echo "PermitRootLogin no"
} > "$HARDEN.new"
rm -f "$HARDEN.old"
[ -f "$HARDEN" ] && cp -p "$HARDEN" "$HARDEN.old"
mv "$HARDEN.new" "$HARDEN"
# sshd -t needs its privilege-separation folder, which socket activation may
# not have made yet.
install -d -m 0755 /run/sshd
if sshd -t 2>"$SSH_LOG"; then
    rm -f "$HARDEN.old"
    if systemctl is-active --quiet ssh && ! systemctl reload ssh >>"$SSH_LOG" 2>&1; then
        print_error "sshd accepted the hardening but would not reload. Output:"
        tail -5 "$SSH_LOG" 2>/dev/null || true
        exit 1
    fi
    if [ "$SSH_LAN_ONLY" = "1" ]; then
        print_success "SSH: no root login, passwords and keys from the LAN."
    else
        print_success "SSH: no root login. Port 22 was NOT limited to the LAN."
    fi
else
    if [ -f "$HARDEN.old" ]; then mv "$HARDEN.old" "$HARDEN"; else rm -f "$HARDEN"; fi
    print_error "sshd rejected the hardening, so the previous file was put back and SSH is unchanged. Output:"
    tail -5 "$SSH_LOG" 2>/dev/null || true
    exit 1
fi

rm -f "$SSH_LOG"
print_success "SSH installation and configuration complete"
