#!/usr/bin/env bash
set -euo pipefail

PROJECT="$1"
HOST_SSH_PORT="$2"
LAN_IF="$3"

if [[ -z "$LAN_IF" || "$LAN_IF" == "auto" ]]; then
  LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
  if [[ -z "$LAN_IF" ]]; then
    echo "Could not detect default route interface"
    exit 1
  fi
fi

TAP="tap-${PROJECT}"

# Must match microvm-net-up.sh: BLOCK-based /30 (valid host addrs .1 and .2 only)
HASH=$(echo -n "$PROJECT" | sha1sum | cut -c1-6)
A=$((0x${HASH:0:2}))
B=$((0x${HASH:2:2}))
SUBNET_A=$(( (A % 250) + 1 ))
BLOCK=$(( (B % 252) / 4 * 4 ))
HOST_IP="172.31.${SUBNET_A}.$((BLOCK + 1))"
GUEST_IP="172.31.${SUBNET_A}.$((BLOCK + 2))"
CIDR="30"

iptables -t nat -D POSTROUTING -s "${HOST_IP}/${CIDR}" -o "$LAN_IF" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$LAN_IF" -o "$TAP" -j ACCEPT 2>/dev/null || true
iptables -D FORWARD -i "$TAP" -o "$LAN_IF" -j ACCEPT 2>/dev/null || true
iptables -t nat -D PREROUTING -i "$LAN_IF" -p tcp --dport "$HOST_SSH_PORT" \
  -j DNAT --to-destination "${GUEST_IP}:22" 2>/dev/null || true
iptables -D FORWARD -p tcp -d "$GUEST_IP" --dport 22 -j ACCEPT 2>/dev/null || true

ip link set "$TAP" down 2>/dev/null || true
ip tuntap del dev "$TAP" mode tap 2>/dev/null || true

echo "[+] Network torn down for ${PROJECT}"
