#!/usr/bin/env bash
set -euo pipefail

PROJECT="$1"           # e.g. myproj
HOST_SSH_PORT="$2"     # e.g. 22240
LAN_IF="$3"            # e.g. eno1, or empty/auto to detect from default route

if [[ -z "$PROJECT" || -z "$HOST_SSH_PORT" ]]; then
  echo "Usage: microvm-net-up.sh <project> <ssh-port> [<lan-if>]"
  exit 1
fi

if [[ -z "$LAN_IF" || "$LAN_IF" == "auto" ]]; then
  LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
  if [[ -z "$LAN_IF" ]]; then
    echo "Could not detect default route interface"
    exit 1
  fi
fi

TAP="tap-${PROJECT}"

# Deterministic /30 based on project name (valid host addrs only: .1 and .2 in each block)
HASH=$(echo -n "$PROJECT" | sha1sum | cut -c1-6)
A=$((0x${HASH:0:2}))
B=$((0x${HASH:2:2}))

SUBNET_A=$(( (A % 250) + 1 ))
BLOCK=$(( (B % 252) / 4 * 4 ))   # 0, 4, 8, ... 248 — start of /30 block in last octet
HOST_IP="172.31.${SUBNET_A}.$((BLOCK + 1))"
GUEST_IP="172.31.${SUBNET_A}.$((BLOCK + 2))"
CIDR="30"

echo "[+] Creating TAP ${TAP}"
ip tuntap add dev "$TAP" mode tap 2>/dev/null || true
ip addr flush dev "$TAP" || true
ip addr add "${HOST_IP}/${CIDR}" dev "$TAP"
ip link set "$TAP" up

echo "[+] Enabling NAT for ${HOST_IP}/${CIDR}"
iptables -t nat -C POSTROUTING -s "${HOST_IP}/${CIDR}" -o "$LAN_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "${HOST_IP}/${CIDR}" -o "$LAN_IF" -j MASQUERADE

echo "[+] Allowing forwarding"
iptables -C FORWARD -i "$LAN_IF" -o "$TAP" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$LAN_IF" -o "$TAP" -j ACCEPT

iptables -C FORWARD -i "$TAP" -o "$LAN_IF" -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -i "$TAP" -o "$LAN_IF" -j ACCEPT

echo "[+] Forwarding LAN port ${HOST_SSH_PORT} → ${GUEST_IP}:22"
iptables -t nat -C PREROUTING -i "$LAN_IF" -p tcp --dport "$HOST_SSH_PORT" \
  -j DNAT --to-destination "${GUEST_IP}:22" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$LAN_IF" -p tcp --dport "$HOST_SSH_PORT" \
     -j DNAT --to-destination "${GUEST_IP}:22"

iptables -C FORWARD -p tcp -d "$GUEST_IP" --dport 22 -j ACCEPT 2>/dev/null \
  || iptables -A FORWARD -p tcp -d "$GUEST_IP" --dport 22 -j ACCEPT

cat <<OUT
TAP=${TAP}
HOST_IP=${HOST_IP}
GUEST_IP=${GUEST_IP}
CIDR=${CIDR}
SSH=ssh -p ${HOST_SSH_PORT} dev@<host-ip>
OUT
