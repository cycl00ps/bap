#!/usr/bin/env bash
# Run all steps from build/Step03.md: Firecracker host networking (TAP + NAT).
# Installs microvm-net-up/down to /usr/local/sbin, runs prereq checks, and sanity tests.
# Usage: bash build/run-step03.sh   or   ./build/run-step03.sh
# Prerequisite: Step 1 and Step 2 done; microvm-net-up.sh and microvm-net-down.sh in the same directory as this script (build/), or set MICROVM_NET_UP / MICROVM_NET_DOWN.
# Exits with 0 if all checks pass, non-zero on first failure.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { echo ""; echo "=== $* ==="; }

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Optional overrides for script locations (default: same directory as this script)
MICROVM_NET_UP="${MICROVM_NET_UP:-$BUILD_DIR/microvm-net-up.sh}"
MICROVM_NET_DOWN="${MICROVM_NET_DOWN:-$BUILD_DIR/microvm-net-down.sh}"

# When run non-interactively, fail fast if sudo would need a password
if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo. Run it from an interactive terminal so you can enter your password,"
  echo "or configure passwordless sudo for your user. Then run: $0"
  exit 1
fi

# --- 3.1 Identify host interfaces (LAN from default route) ---
step "3.1 Identify LAN interface (default route)"
LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
if [[ -z "${LAN_IF}" ]]; then
  fail "No default route or could not derive interface (ip route show default)"
fi
export LAN_IF
ok "LAN_IF=${LAN_IF}"

# --- 3.3 Install networking scripts to /usr/local/sbin ---
step "3.3 Install microvm-net-up/down to /usr/local/sbin"
if [[ ! -r "${MICROVM_NET_UP}" ]]; then
  fail "microvm-net-up.sh not found or not readable: ${MICROVM_NET_UP} (set MICROVM_NET_UP or place script in build/)"
fi
if [[ ! -r "${MICROVM_NET_DOWN}" ]]; then
  fail "microvm-net-down.sh not found or not readable: ${MICROVM_NET_DOWN} (set MICROVM_NET_DOWN or place script in build/)"
fi
ok "Source scripts found"

sudo cp "$MICROVM_NET_UP" "$MICROVM_NET_DOWN" /usr/local/sbin/
sudo chmod +x /usr/local/sbin/microvm-net-up.sh /usr/local/sbin/microvm-net-down.sh

if [[ ! -x /usr/local/sbin/microvm-net-up.sh ]] || [[ ! -x /usr/local/sbin/microvm-net-down.sh ]]; then
  fail "Scripts not executable in /usr/local/sbin after install"
fi
ok "Installed and executable: /usr/local/sbin/microvm-net-up.sh, microvm-net-down.sh"

# --- 3.7 Prereq checks (ip_forward, firewall) ---
step "3.7 Prereq checks (Step 1 must be done)"
val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
if [[ "${val}" != "1" ]]; then
  fail "net.ipv4.ip_forward is not 1 (got: ${val}); complete Step 1 first"
fi
ok "sysctl net.ipv4.ip_forward = 1"

if ! (sudo firewall-cmd --list-ports 2>/dev/null || firewall-cmd --list-ports 2>/dev/null) | grep -q 20000; then
  fail "Firewall port range 20000-29999/tcp not listed; complete Step 1 first (firewall-cmd --list-ports | grep 20000)"
fi
ok "Firewall allows SSH port range (20000)"

# --- 3.5 Test networking: testproj up, verify, down, verify ---
step "3.5 Sanity test: testproj 22240 (up, verify, down, verify)"

cleanup_testproj() {
  sudo /usr/local/sbin/microvm-net-down.sh testproj 22240 "${LAN_IF:-}" 2>/dev/null || true
}
trap cleanup_testproj EXIT INT TERM

# Idempotency: clean any leftover state
sudo /usr/local/sbin/microvm-net-down.sh testproj 22240 "$LAN_IF" 2>/dev/null || true

echo "   Bringing up tap-testproj..."
sudo /usr/local/sbin/microvm-net-up.sh testproj 22240 "$LAN_IF"

# Verify TAP exists
if ! ip addr show tap-testproj &>/dev/null; then
  fail "tap-testproj does not exist after microvm-net-up"
fi
ok "tap-testproj exists"

# Verify IP in 172.31.x.y/30
tap_out=$(ip addr show tap-testproj)
if ! echo "$tap_out" | grep -q '172.31\.'; then
  fail "tap-testproj has no 172.31.x.y address"
fi
if ! echo "$tap_out" | grep -q '/30'; then
  fail "tap-testproj address is not /30"
fi
ok "tap-testproj has 172.31.x.y/30"

# Verify NAT rules (DNAT or 22240 or 172.31)
nat_out=$(sudo iptables -t nat -L -n)
if ! echo "$nat_out" | grep -qE '22240|172\.31|DNAT|MASQUERADE'; then
  fail "NAT table has no expected rules for testproj (22240, 172.31, DNAT/MASQUERADE)"
fi
ok "NAT rules present"

# Verify FORWARD rules (tap-testproj or 172.31)
fwd_out=$(sudo iptables -L FORWARD -n)
if ! echo "$fwd_out" | grep -qE 'tap-testproj|172\.31'; then
  fail "FORWARD chain has no expected rules for tap-testproj or 172.31"
fi
ok "FORWARD rules present"

# Teardown
echo "   Tearing down tap-testproj..."
sudo /usr/local/sbin/microvm-net-down.sh testproj 22240 "$LAN_IF"
trap - EXIT INT TERM

# Verify teardown: tap must not exist
if ip addr show tap-testproj &>/dev/null; then
  fail "tap-testproj still exists after microvm-net-down"
fi
ok "tap-testproj removed after net-down"

# --- 3.7 Final: sanity project up/down ---
step "3.7 Final checklist: sanity 22250 up and down"
sudo /usr/local/sbin/microvm-net-up.sh sanity 22250 "$LAN_IF"
ok "microvm-net-up.sh sanity 22250 succeeded"
sudo /usr/local/sbin/microvm-net-down.sh sanity 22250 "$LAN_IF"
ok "microvm-net-down.sh sanity 22250 succeeded"

if ip addr show tap-sanity &>/dev/null; then
  fail "tap-sanity still exists after net-down"
fi
ok "tap-sanity removed after net-down"

echo ""
echo -e "${GREEN}=== Step 3 complete: Firecracker host networking (TAP + NAT) installed and verified ===${NC}"
