#!/usr/bin/env bash
set -e

# =============================================================================
# The network upstream packages run on: they answer, but cannot start a
# connection of their own, to the internet or to this machine.
#
#   upstream_net.sh
#
# Idempotent, and run as ExecStartPre by every upstream unit, because a reboot
# clears the firewall rules while the units come straight back.
#
# Why: a supply-chain attack arrives as an ordinary release. Code that cannot
# phone home or reach Apache, SSH or 1Password Connect on this machine has very
# little left to do.
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1"; }

NET="upstream-net"
SUBNET="172.30.0.0/24"

[ "$EUID" -eq 0 ] || { print_error "This needs root: it changes the firewall."; exit 2; }

docker network inspect "$NET" >/dev/null 2>&1 \
    || docker network create --driver bridge --subnet "$SUBNET" "$NET" >/dev/null

# Replies to connections made TO a container are ESTABLISHED and pass; only
# connections a container opens itself are NEW and dropped. FORWARD covers
# everything beyond this machine, INPUT this machine itself.
rule=(-s "$SUBNET" -m conntrack --ctstate NEW -j DROP)
iptables -C DOCKER-USER "${rule[@]}" 2>/dev/null || iptables -I DOCKER-USER "${rule[@]}"
iptables -C INPUT "${rule[@]}" 2>/dev/null || iptables -I INPUT "${rule[@]}"
