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

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }

# The directly connected subnets, as add_smb.sh finds them. SSH_ALLOW_FROM
# (space separated) overrides, for a machine reached through a VPN.
ssh_sources() {
    if [ -n "${SSH_ALLOW_FROM:-}" ]; then
        printf '%s\n' $SSH_ALLOW_FROM
        return 0
    fi
    { ip -o -4 route show; ip -o -6 route show; } 2>/dev/null \
        | awk '$1 == "default" || / via / || $1 !~ /\// { next }
               { d = ""; for (i = 1; i < NF; i++) if ($i == "dev") d = $(i + 1) }
               d !~ /^(lo|docker|br-|veth|wg)/ { print $1 }' \
        | sort -u
}

if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mThis script requires sudo privileges to run properly.\e[0m"
    echo -e "\e[33mPlease run with: sudo $0\e[0m"
    exit 1
fi

# Watch-only progress for irreversible package transactions: reports elapsed
# time but never kills the command — a SIGKILL mid-dpkg can corrupt package state
show_progress_watch_only() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)
    while kill -0 "$cmd_pid" 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo
    wait "$cmd_pid"
    return $?
}

if ! dpkg -s openssh-server &> /dev/null; then
    print_status "Installing OpenSSH server..."
    # Package-list update is kill-safe/retryable — timeout is fine here
    timeout 180 apt-get update -qq --fix-missing
    # The install is an irreversible dpkg transaction — never run it under a kill timeout
    if ! show_progress_watch_only "📦 Installing openssh-server" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server; then
        print_error "Failed to install openssh-server"
        exit 1
    fi
fi

SSH_LOG="/tmp/add_ssh.log"

# Ubuntu 24.04+ socket-activates sshd (ssh.socket) — either unit active is fine
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet ssh.socket; then
    print_status "Enabling and starting SSH service..."
    if ! { sudo systemctl enable ssh && sudo systemctl start ssh; } >"$SSH_LOG" 2>&1; then
        print_error "Failed to enable/start SSH — output:"
        tail -5 "$SSH_LOG" 2>/dev/null || true
        exit 1
    fi
fi

if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    # PORT 22 FROM THE LAN ONLY. Audit 2026-10-02, H3.
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
        print_status "SSH allowed from: ${SSH_FROM[*]}"

        # An open-to-everyone rule is reported, never deleted here: under sudo
        # this script cannot tell which session the delete would cut off.
        if ufw status | grep -qE "^(22(/tcp)?|OpenSSH)( \(v6\))? +(ALLOW|LIMIT) +Anywhere"; then
            print_info "Port 22 is still open to everyone by an older rule."
            print_action "From the LAN or the keyboard: sudo ufw delete allow 22/tcp (or OpenSSH)"
        fi
    fi
fi

# KEY-ONLY LOGIN, but only once a key is in place: on a fresh drive the PC's key
# is not there yet, and turning passwords off then would lock the owner out.
REAL_USER="${SUDO_USER:-}"
REAL_HOME="$(getent passwd "${REAL_USER:-root}" | cut -d: -f6)"
HARDEN="/etc/ssh/sshd_config.d/10-linuxbasics-hardening.conf"
{
    echo "# Written by add_ssh.sh. Audit 2026-10-02, H3."
    echo "PermitRootLogin no"
    if [ -n "$REAL_USER" ] && [ -s "$REAL_HOME/.ssh/authorized_keys" ] \
       && journalctl -u ssh --no-pager 2>/dev/null | grep -q "Accepted publickey for $REAL_USER "; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
    fi
} > "$HARDEN.new"
[ -f "$HARDEN" ] && cp -p "$HARDEN" "$HARDEN.old"
mv "$HARDEN.new" "$HARDEN"
if sshd -t 2>"$SSH_LOG"; then
    rm -f "$HARDEN.old"
    systemctl reload ssh 2>/dev/null || true
    if grep -q "^PasswordAuthentication no" "$HARDEN"; then
        print_success "SSH: keys only, no root login."
    else
        print_info "SSH: no root login. Passwords still work: $REAL_USER has no authorized key yet."
        print_action "From your PC: ssh-copy-id ${REAL_USER:-<user>}@$(hostname -I | awk '{print $1}'), then run this again."
    fi
else
    if [ -f "$HARDEN.old" ]; then mv "$HARDEN.old" "$HARDEN"; else rm -f "$HARDEN"; fi
    print_error "sshd rejected the hardening, so the previous file was put back and SSH is unchanged. Output:"
    tail -5 "$SSH_LOG" 2>/dev/null || true
    exit 1
fi

echo -e "\e[32m✅ SSH installation and configuration complete\e[0m"
