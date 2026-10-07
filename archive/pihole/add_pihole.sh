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
# Pi-hole as a Docker container: network-wide DNS with ad and tracker blocking.
#
# WHY DOCKER AND NOT THE NATIVE INSTALLER
#
# Pi-hole ships no apt repository, so the native route is `curl | bash` and it
# reaches into the system to take port 53, which on Ubuntu means disabling
# systemd-resolved's stub listener. Get that wrong on a remote machine and the
# machine has no resolver, which is a bad afternoon on a box that also serves
# mail and web. In a container the conflict is settled by a bind address
# instead, and the worst failure is a container that will not start.
#
# THE BIND ADDRESS IS THE SECURITY BOUNDARY FOR IPv4. FOR IPv6 IT IS UFW.
#
# Docker publishes IPv4 ports by writing its own iptables rules, and those are
# consulted BEFORE UFW's. A published port is therefore reachable even when UFW
# says otherwise, and this surprises people every time.
#
# IPv6 is the other way round. Without ip6tables enabled in the daemon, Docker
# publishes a v6 port through docker-proxy, a userspace process binding the host
# address, so the traffic passes the normal INPUT chain and UFW's default deny
# really does drop it. Both were measured on this fleet on 2026-09-02.
#
# So exposure is controlled by WHERE each port is bound, plus a UFW rule that is
# cosmetic for v4 and load bearing for v6:
#
#   DNS   bound to this machine's LAN address, so the LAN can resolve and
#         127.0.0.53 is left to systemd-resolved, which keeps the machine's own
#         name resolution working.
#   DNSv6 bound to this machine's UNIQUE LOCAL address, not its global one: a
#         global address carries the ISP's prefix and vanishes when that
#         rotates, taking the container's ability to start with it.
#   Web   bound to 127.0.0.1, so the admin page is reachable only through a
#         reverse proxy on this machine or over a tunnel. Never from the LAN
#         directly, because it is plain HTTP with a password on it.
#
# WHY IPv6 IS NOT OPTIONAL ON A FRITZ!BOX LAN
#
# A router that announces a DNSv6 server hands its clients a v6 resolver and
# nothing else. An IPv4-only Pi-hole is then never asked anything: it resolves
# and blocks perfectly when queried by hand and does nothing for the network.
# That is the state this fleet was in until 2026-09-02.
#
# THE ADMIN PASSWORD IS NEVER AN ARGUMENT
#
# It is asked for on the terminal and written to an env file at mode 600, so it
# is not in `ps`, not in the shell history, and not in the compose file.
#
# Usage:
#   add_pihole.sh                                   # prompts for the password
#   add_pihole.sh --web-port 15001 --upstream 9.9.9.9,149.112.112.112
#   add_pihole.sh --dns-bind 192.168.1.10 --data-dir /opt/pihole
#   add_pihole.sh --dns-bind6 fd6f:2e2f:34d3:0:da3a:ddff:fe92:1573
#   add_pihole.sh --no-ipv6                         # IPv4 only, no warning
#
# Safe to re-run: the data directory, the blocklists and the password are left
# alone unless a new password is given.
#
# Exit codes:
#   0  the container is up and answering DNS
#   1  something needed for the run is missing or failed
#   2  bad usage
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

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

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. An image
# pull killed halfway leaves a partial layer cache. Output is captured, never
# discarded, so a failure can be read rather than guessed at.
show_spinner_watch_only() {
    local message="$1"
    shift
    local log
    log="$(mktemp)"
    "$@" >"$log" 2>&1 &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        spin_tick "$message" || break
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    printf '\r\033[K'
    if [ "$exit_code" -ne 0 ]; then
        print_error "$message failed (exit $exit_code)"
        tail -n 20 "$log" >&2
        print_warning "Full log: $log"
    else
        rm -f "$log"
    fi
    return $exit_code
}

# One asterisk per character, as they arrive. Duplicated from add_auth_users.sh
# per the convention that each script stays runnable alone.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            ''|$'\n')       break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

read_password_twice() {
    local p1 p2
    while true; do
        read_secret "   Admin password: " || return 1
        p1="$SECRET"
        unset SECRET
        if [ ${#p1} -lt 8 ]; then
            printf "   \033[33mAt least 8 characters. This one blocks or unblocks your whole network.\033[0m\n" > /dev/tty
            continue
        fi
        case "$p1" in
            *"'"*)
                printf "   \033[33mNo single quotes: the password is stored quoted in an env file.\033[0m\n" > /dev/tty
                continue ;;
        esac
        read_secret "   Again: " || return 1
        p2="$SECRET"
        unset SECRET
        if [ "$p1" = "$p2" ]; then
            PASSWORD="$p1"
            return 0
        fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

# --- Arguments ---------------------------------------------------------------
WEB_PORT="15001"
UPSTREAM="9.9.9.9,149.112.112.112"
DNS_BIND=""
DNS_BIND6=""
LAN_CIDR6=""
WANT_IPV6="yes"
DATA_DIR="/opt/pihole"
IMAGE="pihole/pihole:latest"

while [ $# -gt 0 ]; do
    case "$1" in
        --web-port)  WEB_PORT="$2"; shift 2 ;;
        --upstream)  UPSTREAM="$2"; shift 2 ;;
        --dns-bind)  DNS_BIND="$2"; shift 2 ;;
        --dns-bind6) DNS_BIND6="$2"; shift 2 ;;
        --no-ipv6)   WANT_IPV6="no"; DNS_BIND6=""; shift ;;
        --data-dir)  DATA_DIR="$2"; shift 2 ;;
        --image)     IMAGE="$2"; shift 2 ;;
        -h|--help)
            sed -n '18,74p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            print_error "Unknown option: $1"
            exit 2 ;;
        *)
            print_error "Unexpected argument: $1"
            exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0 $*"
    exit 2
fi

print_header "Pi-hole"

# --- Pre-flight --------------------------------------------------------------
# Nothing is written until the run is known to be able to finish. A half-created
# container with a half-taken port 53 is worse than a refusal.
ERRORS=()
WARNINGS=()

if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed, and this runs Pi-hole as a container")
    ERRORS+=("  Install it first: sudo bash $(dirname "$0")/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but the daemon is not answering")
    ERRORS+=("  Check it: sudo systemctl status docker")
elif ! docker compose version >/dev/null 2>&1; then
    ERRORS+=("The docker compose plugin is missing")
    ERRORS+=("  Install it: sudo apt-get install -y docker-compose-plugin")
fi

# The LAN address, so DNS is published there rather than on 0.0.0.0. Publishing
# on 0.0.0.0 would collide with systemd-resolved on 127.0.0.53 and take the
# machine's own resolver with it.
if [ -z "$DNS_BIND" ]; then
    DNS_BIND="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    if [ -z "$DNS_BIND" ]; then
        ERRORS+=("Could not work out this machine's LAN address for DNS to listen on")
        ERRORS+=("  Give it explicitly: --dns-bind 192.168.1.10")
    fi
fi

# The IPv6 address, because a router that hands out a DNSv6 server leaves an
# IPv4-only Pi-hole unused: clients ask the resolver they were given and never
# see it. Measured on this fleet 2026-09-02, where the only resolver a Windows
# PC held was the router's ULA.
#
# The UNIQUE LOCAL address is preferred over the global one on purpose. A global
# address carries the ISP's prefix and changes when that prefix rotates, which
# would leave the container unable to bind and the whole LAN without DNS. A ULA
# is generated from the interface's MAC under a prefix the router owns, so it
# survives. If the router stops announcing the ULA prefix the address goes and
# this script has to be re-run: that is a re-run, not a repair.
if [ "$WANT_IPV6" = "yes" ] && [ -z "$DNS_BIND6" ]; then
    DNS_BIND6="$(ip -6 addr show scope global 2>/dev/null \
        | sed -n 's/.*inet6 \(f[cd][0-9a-f]*:[0-9a-f:]*\)\/.*/\1/p' | head -1)"
    if [ -z "$DNS_BIND6" ]; then
        WARNINGS+=("No unique local IPv6 address found, so DNS will be IPv4 only")
        WARNINGS+=("  A router handing out a DNSv6 server will bypass Pi-hole entirely")
        WARNINGS+=("  Give one explicitly: --dns-bind6 fd00:...  or silence this: --no-ipv6")
    fi
fi

if [ -n "$DNS_BIND6" ]; then
    # The kernel compares addresses, not strings. An uppercase or uncompressed
    # spelling of an address the machine really holds is the same address, and
    # a grep for the canonical form would call it missing.
    if [ -z "$(ip -6 addr show to "$DNS_BIND6" 2>/dev/null)" ]; then
        ERRORS+=("This machine does not hold the IPv6 address ${DNS_BIND6}")
        ERRORS+=("  Docker cannot publish on an address that is not here; the container would fail to start")
        ERRORS+=("  List them: ip -6 addr show scope global")
    fi

    # The prefix comes from the routing table, never from slicing the address.
    # `ip` compresses any run of zero hextets, so `fd00::5` and
    # `fd6f:2e2f:34d3::1` cut into nonsense on a colon count. The router's own
    # advertisement already carries the prefix in canonical form.
    LAN_CIDR6="$(ip -6 route show proto ra 2>/dev/null \
        | awk '/^f[cd][0-9a-f]*:/ && / dev / && !/ via /{print $1; exit}')"
    if [ -z "$LAN_CIDR6" ]; then
        LAN_CIDR6="$(ip -6 route show proto kernel 2>/dev/null \
            | awk '/^f[cd][0-9a-f]*:/{print $1; exit}')"
    fi
    if [ -z "$LAN_CIDR6" ]; then
        WARNINGS+=("No advertised IPv6 prefix found, so the UFW rule cannot be scoped")
        WARNINGS+=("  DNS over IPv6 will be published but BLOCKED until a rule is added by hand")
    fi
fi

if ! echo "$WEB_PORT" | grep -qE '^[0-9]+$' || [ "$WEB_PORT" -lt 1024 ] || [ "$WEB_PORT" -gt 65535 ]; then
    ERRORS+=("--web-port must be a number between 1024 and 65535, not '$WEB_PORT'")
fi

IFS=',' read -r -a _ups <<< "$UPSTREAM"
for u in ${_ups+"${_ups[@]}"}; do
    u="$(echo "$u" | xargs)"
    [ -z "$u" ] && continue
    if ! echo "$u" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
        ERRORS+=("--upstream entry '$u' is not an IP address")
    fi
done

# Port 53 on the bind addresses specifically. systemd-resolved holding
# 127.0.0.53 is expected and fine, so the check is deliberately narrow.
if command -v ss >/dev/null 2>&1; then
    _taken() {
        ss -lnup 2>/dev/null | grep -qF "$1:53 " || ss -lntp 2>/dev/null | grep -qF "$1:53 "
    }
    _is_pihole() {
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pihole
    }

    if [ -n "$DNS_BIND" ] && _taken "$DNS_BIND" && ! _is_pihole; then
        ERRORS+=("Something is already listening on ${DNS_BIND}:53 and it is not Pi-hole")
        ERRORS+=("  Find it: sudo ss -lnup | grep ':53'")
    fi

    if [ -n "$DNS_BIND6" ] && _taken "[${DNS_BIND6}]" && ! _is_pihole; then
        ERRORS+=("Something is already listening on [${DNS_BIND6}]:53 and it is not Pi-hole")
        ERRORS+=("  Find it: sudo ss -lnup | grep ':53'")
    fi

    if ss -lnt 2>/dev/null | grep -qF "127.0.0.1:${WEB_PORT} " && ! _is_pihole; then
        ERRORS+=("Something is already listening on 127.0.0.1:${WEB_PORT}")
    fi
fi

ENV_FILE="$DATA_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ ! -r /dev/tty ]; then
    ERRORS+=("No terminal to ask for an admin password, and no existing $ENV_FILE")
    ERRORS+=("  Run this from a terminal once, then it is re-runnable unattended.")
fi


if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

for w in ${WARNINGS+"${WARNINGS[@]}"}; do print_warning "$w"; done

print_status "DNS:       ${DNS_BIND}:53, so the LAN can resolve through it"
if [ -n "$DNS_BIND6" ]; then
    if [ -n "$LAN_CIDR6" ]; then
        print_status "DNS v6:    [${DNS_BIND6}]:53, opened in UFW for ${LAN_CIDR6}"
    else
        print_status "DNS v6:    [${DNS_BIND6}]:53, but NO UFW rule, so it will be blocked"
    fi
else
    print_status "DNS v6:    none, so a router handing out a DNSv6 server bypasses Pi-hole"
fi
print_status "Admin:     127.0.0.1:${WEB_PORT}, reachable only via a proxy or a tunnel"
print_status "Upstream:  $UPSTREAM"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- The data directory ------------------------------------------------------
mkdir -p "$DATA_DIR"
chmod 0755 "$DATA_DIR"

# --- The compose file --------------------------------------------------------
# Pi-hole v6 renamed its environment variables to FTLCONF_*. The v5 names are
# set alongside them because an unknown variable is ignored by both, and that
# costs four lines against an install that silently comes up with no password.
# Empty when there is no IPv6 address, and an empty line inside a YAML list is
# ignored, so the compose file stays valid either way.
DNS_V6_PORTS=""
if [ -n "$DNS_BIND6" ]; then
    DNS_V6_PORTS="      - \"[${DNS_BIND6}]:53:53/tcp\"
      - \"[${DNS_BIND6}]:53:53/udp\""
fi

COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Etc/UTC')"

NEW_COMPOSE="$(cat <<EOF
# Generated by add_pihole.sh. Do not edit by hand: the next run overwrites it.
# Re-run the script with different flags instead.
services:
  pihole:
    container_name: pihole
    image: ${IMAGE}
    restart: unless-stopped
    ports:
      # Bound to an address on purpose. Docker's published IPv4 ports bypass
      # UFW, so the bind address is what decides who can reach these. The IPv6
      # publishes go through docker-proxy in userspace, so UFW gates those; the
      # firewall block below opens them.
      - "${DNS_BIND}:53:53/tcp"
      - "${DNS_BIND}:53:53/udp"
${DNS_V6_PORTS}
      - "127.0.0.1:${WEB_PORT}:80/tcp"
    environment:
      TZ: "${TZ_VALUE}"
      FTLCONF_webserver_api_password: "\${PIHOLE_PASSWORD}"
      FTLCONF_dns_upstreams: "${UPSTREAM//,/;}"
      FTLCONF_dns_listeningMode: "all"
      # Pi-hole ships 16 API session seats and keeps sessions in its database,
      # so they outlive a restart. Sixteen is spent quickly by a browser that
      # logs in a few times and by anything scripted, and the page then refuses
      # a CORRECT password with "API seats exceeded", which reads as a wrong one.
      FTLCONF_webserver_api_max_sessions: "64"
      WEBPASSWORD: "\${PIHOLE_PASSWORD}"
      PIHOLE_DNS_: "${UPSTREAM//,/;}"
    volumes:
      - ./etc-pihole:/etc/pihole
    cap_add:
      - NET_ADMIN
    healthcheck:
      test: ["CMD", "dig", "+short", "+norecurse", "+retry=0", "@127.0.0.1", "pi.hole"]
      interval: 30s
      retries: 3
EOF
)"

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Start it ----------------------------------------------------------------
# `docker pull` rather than `docker compose pull`: Compose would interpolate the
# compose file, and on a first install the password variable does not exist yet,
# so it would warn about a blank value before anyone has been asked for one.
if ! show_spinner_watch_only "Pulling the Pi-hole image" \
    docker pull "$IMAGE"; then
    print_error "Could not pull $IMAGE."
    exit 1
fi

# --- The password ------------------------------------------------------------
#
# Asked AFTER the image is pulled, so a failed download never costs a typed
# password. It has to be written before "up -d": Compose reads $ENV_FILE to
# fill in the password variable when it starts the container.
# The password is set on EVERY run that has a terminal, by decision 2026-09-01:
# a run that keeps the old one leaves no way to change it except deleting this
# file by hand, which is what happened when the stored value had to be rotated.
#
# Without a terminal the existing file is kept instead, so the pipeline and any
# unattended re-run still work. Pre-flight already refuses the case where there
# is neither.
if [ ! -r /dev/tty ]; then
    print_success "Keeping the existing admin password ($ENV_FILE): no terminal to ask at."
else
    echo ""
    print_status "Pi-hole's admin page has a password and no username."
    if [ -f "$ENV_FILE" ]; then
        print_status "This replaces the password already stored at $ENV_FILE."
    fi
    if ! read_password_twice; then
        print_error "No password given, so the admin page would be wide open."
        exit 1
    fi
    # Single quoted, because Compose reads this file literally but a shell that
    # sources it does not: an unquoted & backgrounds the line and truncates the
    # password without a word. A single quote is refused at the prompt, so there
    # is nothing left to escape here.
    ( umask 077; printf "PIHOLE_PASSWORD='%s'\n" "$PASSWORD" > "$ENV_FILE" )
    unset PASSWORD
    chmod 0600 "$ENV_FILE"
    print_success "Password stored at $ENV_FILE (mode 600)."
fi

if ! show_spinner_watch_only "Starting Pi-hole" \
    docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Pi-hole did not start."
    print_warning "Logs: sudo docker logs pihole"
    exit 1
fi

# --- Prove it answers --------------------------------------------------------
# A container that is "up" is not the same as a resolver that works, and the
# difference is worth thirty seconds now rather than at the first blank browser.
WAIT_LIMIT=60
WAIT_START="$(date +%s)"
RESOLVED=0
while [ $(( $(date +%s) - WAIT_START )) -lt "$WAIT_LIMIT" ]; do
    if command -v dig >/dev/null 2>&1; then
        dig +short +time=2 +tries=1 "@${DNS_BIND}" example.com >/dev/null 2>&1 && { RESOLVED=1; break; }
    else
        docker exec pihole dig +short +time=2 +tries=1 @127.0.0.1 example.com >/dev/null 2>&1 \
            && { RESOLVED=1; break; }
    fi
    spin_tick "Waiting for Pi-hole to answer DNS, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
done
printf '\r\033[K'

if [ "$RESOLVED" -eq 1 ]; then
    print_success "Pi-hole is resolving on ${DNS_BIND}:53."
else
    print_error "Pi-hole is running but did not answer a query within ${WAIT_LIMIT}s."
    print_warning "Logs: sudo docker logs pihole"
    print_warning "Try by hand: dig @${DNS_BIND} example.com"
    exit 1
fi

# --- The firewall ------------------------------------------------------------
# The two families are NOT symmetrical here, and the difference is the whole
# reason this block exists twice.
#
# IPv4: Docker opened port 53 by writing its own iptables rules and UFW was
#       never consulted, so the rule below changes nothing about reachability.
#       It makes `ufw status` tell the truth about what this machine answers on.
# IPv6: docker-proxy binds the host address in USERSPACE, so the traffic passes
#       the normal INPUT chain and UFW's "deny (incoming)" default really does
#       drop it. The v6 rule is load bearing: without it the listener is
#       unreachable. Measured on 2026-09-02.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
        | sed -E 's/\.[0-9]+$/.0\/24/')"
    if [ -z "$LAN_CIDR" ]; then
        print_warning "No default route, so no DNS firewall rule was added."
        print_warning "Add it by hand: sudo ufw allow from <your-lan>/24 to any port 53"
    elif ufw status | grep -qE "^53(/(tcp|udp))?[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR}([[:space:]]|$)"; then
        print_success "UFW already allows DNS from $LAN_CIDR."
    elif ufw allow from "$LAN_CIDR" to any port 53 proto udp >/dev/null 2>&1 \
      && ufw allow from "$LAN_CIDR" to any port 53 proto tcp >/dev/null 2>&1; then
        print_success "UFW now allows DNS from $LAN_CIDR."
    else
        print_warning "UFW refused the DNS rule, so 'ufw status' will not show port 53."
        print_warning "Add it by hand: sudo ufw allow from $LAN_CIDR to any port 53 proto udp"
    fi

    if [ -n "$DNS_BIND6" ]; then
        if [ -z "$LAN_CIDR6" ]; then
            print_warning "No IPv6 LAN prefix worked out, so DNS over IPv6 will be BLOCKED."
            print_warning "Add it by hand: sudo ufw allow from <prefix>::/64 to any port 53"
        elif ufw status | grep -qE "^53(/(tcp|udp))?([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR6}([[:space:]]|$)"; then
            print_success "UFW already allows DNS from $LAN_CIDR6."
        elif ufw allow from "$LAN_CIDR6" to any port 53 proto udp >/dev/null 2>&1 \
          && ufw allow from "$LAN_CIDR6" to any port 53 proto tcp >/dev/null 2>&1; then
            print_success "UFW now allows DNS from $LAN_CIDR6."
        else
            print_warning "UFW refused the IPv6 DNS rule, so DNS over IPv6 is BLOCKED."
            print_warning "Add it by hand: sudo ufw allow from $LAN_CIDR6 to any port 53 proto udp"
        fi
    fi
else
    print_warning "UFW is not active, so no firewall rules were added."
fi

# --- What to do with it ------------------------------------------------------
echo ""
print_success "Pi-hole is up."
print_status "Admin page:  http://127.0.0.1:${WEB_PORT}/admin  (loopback only)"
print_status "Container:   sudo docker logs pihole"
print_status "Restart:     sudo docker compose --project-directory $DATA_DIR restart"

echo ""
print_header "Two steps left, both by hand"
echo "1. Reach the admin page. It is bound to loopback, so pick one:"
echo "     - a reverse-proxy vhost on this machine, or"
echo "     - over Tailscale, or"
echo "     - an SSH tunnel:  ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} <user>@$(hostname)"
echo ""
echo "2. Point devices at it, and check WHICH family your router hands out."
echo "   A router that announces a DNSv6 server gives its clients a v6"
echo "   resolver and nothing else, so setting only the IPv4 address leaves"
echo "   Pi-hole unused while it looks perfectly healthy from this machine."
echo ""
echo "   IPv4 DNS server:  ${DNS_BIND}"
if [ -n "$DNS_BIND6" ]; then
    echo "   IPv6 DNS server:  ${DNS_BIND6}"
    echo ""
    echo "   On a FRITZ!Box: Home Network > Network > Network Settings > IPv6,"
    echo "   'Local DNSv6 server'. It is eight boxes, one hextet each, and it"
    echo "   wants the WHOLE address, not a suffix. Tick 'Also announce DNSv6"
    echo "   server via router advertisement (RFC 5006)' above it as well."
else
    echo "   IPv6 DNS server:  none. If your router announces one, Pi-hole is"
    echo "                     bypassed. Re-run without --no-ipv6."
fi
echo ""
echo "   Check a device afterwards, because this is the step that silently"
echo "   does nothing:"
echo "     Windows:  ipconfig /all | findstr /i \"DNS Servers\""
echo "     Linux:    resolvectl status | grep 'DNS Server'"
echo "   Then prove it blocks:  nslookup doubleclick.net <the address above>"
echo "   A 0.0.0.0 answer is Pi-hole. A real address is not."
echo ""
print_warning "Test one device first. If DNS breaks, every device on the LAN breaks"
print_warning "together, and the symptom is 'the internet is down' rather than 'DNS'."
