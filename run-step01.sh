#!/usr/bin/env bash
# Run and verify all steps from build/Step01.md — Prepare AlmaLinux 10 for Firecracker
# Run as a non-root user with sudo. Exits with 0 if all checks pass, non-zero on first failure.
# Run from an interactive terminal so you can enter your sudo password when prompted.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { echo ""; echo "=== $* ==="; }

# When run non-interactively (e.g. from CI), fail fast with a clear message if sudo would need a password
if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo. Run it from an interactive terminal so you can enter your password,"
  echo "or configure passwordless sudo for your user. Then run: $0"
  exit 1
fi

# --- 1.1 Verify hardware virtualization ---
step "1.1 Verify hardware virtualization"
if ! lscpu | grep -qE 'Virtualization|Vendor ID'; then
  fail "lscpu did not show Virtualization or Vendor ID"
fi
# lscpu pads the value (e.g. "Virtualization:                          VT-x"), so allow optional whitespace
if lscpu | grep -qE 'Virtualization:[[:space:]]*VT-x'; then
  ok "Virtualization: VT-x (Intel)"
elif lscpu | grep -qE 'Virtualization:[[:space:]]*AMD-V'; then
  ok "Virtualization: AMD-V (AMD)"
else
  fail "Expected Virtualization: VT-x or AMD-V; enable in BIOS/UEFI"
fi

if ! lsmod | grep -q kvm; then
  fail "KVM modules not loaded (lsmod | grep kvm); enable virtualization in BIOS/UEFI"
fi
if lsmod | grep -q kvm_intel; then
  ok "kvm_intel, kvm loaded"
elif lsmod | grep -q kvm_amd; then
  ok "kvm_amd, kvm loaded"
else
  fail "Expected kvm_intel or kvm_amd + kvm in lsmod"
fi

# --- 1.2 Install base packages ---
step "1.2 Install base packages (dnf)"
sudo dnf install -y \
  qemu-kvm \
  libvirt \
  iproute \
  iptables-nft \
  firewalld \
  util-linux \
  curl \
  wget \
  tar \
  gzip \
  socat \
  jq
ok "Base packages installed"

# --- 1.3 Enable and start services ---
step "1.3 Enable and start libvirtd and firewalld"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now firewalld
ok "Services enabled and started"

if ! systemctl is-active --quiet libvirtd; then
  fail "libvirtd is not active"
fi
ok "libvirtd is active"

if ! systemctl is-active --quiet firewalld; then
  fail "firewalld is not active"
fi
ok "firewalld is active"

# --- 1.4 Verify /dev/kvm and group ---
step "1.4 Verify /dev/kvm and kvm group"
if [[ ! -c /dev/kvm ]]; then
  fail "/dev/kvm does not exist or is not a character device"
fi
# Owner must be root, group must be kvm (permission bits vary: 660 on some distros, 666 on Fedora/AlmaLinux)
owner=$(stat -c '%U' /dev/kvm 2>/dev/null)
group=$(stat -c '%G' /dev/kvm 2>/dev/null)
if [[ "${owner}" != "root" || "${group}" != "kvm" ]]; then
  fail "/dev/kvm has unexpected owner:group (got ${owner}:${group}, expected root:kvm)"
fi
ok "/dev/kvm exists with correct owner (root) and group (kvm)"

sudo usermod -aG kvm "$USER"
if groups "$USER" | grep -q kvm; then
  ok "User $USER is in group kvm"
else
  warn "User added to kvm group; run 'newgrp kvm' or log out and back in for access"
fi

# --- 1.5 IP forwarding ---
step "1.5 Enable IP forwarding"
sudo sysctl -w net.ipv4.ip_forward=1
sudo tee /etc/sysctl.d/99-firecracker.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system >/dev/null

val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
if [[ "${val}" != "1" ]]; then
  fail "net.ipv4.ip_forward is not 1 (got: ${val})"
fi
ok "net.ipv4.ip_forward = 1"

# --- 1.6 Firewall ports for microVM SSH ---
step "1.6 Configure firewall (20000-29999/tcp)"
sudo firewall-cmd --permanent --add-port=20000-29999/tcp
sudo firewall-cmd --reload

if ! sudo firewall-cmd --list-ports | grep -q '20000-29999/tcp'; then
  fail "Port range 20000-29999/tcp not in firewall (list-ports)"
fi
ok "Ports 20000-29999/tcp open"

# --- 1.7 LAN interface ---
step "1.7 Identify LAN interface (default route)"
if ! ip route show default | head -1; then
  fail "No default route (ip route show default)"
fi
ok "Default route shown (note the interface name for Firecracker NAT)"
LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
if [[ -n "${LAN_IF}" ]]; then
  export LAN_IF
  echo "LAN_IF=${LAN_IF} (exported for Step 3 and Step 4)"
else
  echo "LAN_IF could not be detected from default route"
fi

# --- 1.8 Final verification checklist ---
step "1.8 Final Step 1 verification"
# Run as normal user where possible
if [[ ! -r /dev/kvm ]]; then
  warn "Current shell cannot read /dev/kvm; run 'newgrp kvm' or log out and back in, then re-run this script or: ls /dev/kvm"
else
  ls -l /dev/kvm >/dev/null && ok "ls /dev/kvm"
fi

val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
[[ "${val}" = "1" ]] && ok "sysctl net.ipv4.ip_forward" || fail "sysctl net.ipv4.ip_forward"

if firewall-cmd --state 2>/dev/null | grep -q running; then
  ok "firewall-cmd --state"
else
  # May need root for --state in some setups
  sudo firewall-cmd --state | grep -q running && ok "firewall-cmd --state (sudo)"
fi

ip route show default >/dev/null && ok "ip route show default"

echo ""
echo -e "${GREEN}=== Step 1 complete: host is ready for Firecracker ===${NC}"
