#!/usr/bin/env bash
# Run steps from build/Step04.md: Firecracker microVM (kernel, base rootfs, per-project bring-up, optional teardown).
# Usage: ./build/run-step04.sh [PROJECT] [SSH_PORT] [--setup-only|--no-setup|--teardown]
# Prerequisite: Steps 1–3 done (host prep, Firecracker + jailer in /usr/local/bin, microvm-net-up/down).
# Optional: DEV_PASSWORD env sets root/dev password in base image (default: microvm). Change with passwd inside VM.
# If kernel download fails, place a Firecracker-compatible kernel in the build directory next to this script (e.g. build/vmlinux-5.10.bin) or at $HOME/vmlinux-5.10.bin and re-run.
# Exits 0 if all steps pass; non-zero on first failure with [FAIL] message.
#
# How to test:
#   - Script exit code 0 = automated steps passed.
#   - From host: ping -c 2 GUEST_IP (script runs this and reports [OK] or [WARN]).
#   - From another machine: ssh -p SSH_PORT dev@HOST_LAN_IP (password: microvm or DEV_PASSWORD); inside VM: ip addr; ping -c 2 1.1.1.1.
#   - On failure: see [FAIL] message; check Step 1–3 or logs: /var/log/firecracker/PROJECT.log, /srv/jailer/firecracker/PROJECT/root/firecracker.log.
#   - With --teardown: after run, tap-PROJECT and jailer bind mounts should be gone.
#   - If password setup fails (chpasswd "cannot open" or "failure while writing" to shadow), SELinux may be blocking it; try: sudo setenforce 0, or see Step04.md.
#   - Running microVMs: count with  ps -eo args | grep '[f]irecracker' | grep -- '--id' | wc -l ; list ids with  ps -eo args | grep '[f]irecracker' | grep -- '--id' | sed -n 's/.*--id[= ]\([^ ]*\).*/\1/p'

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure we start at column 1 (fixes misalignment when jailer/timeout write to terminal)
term_bol() { printf '\n\r\033[K'; }

ok()  { term_bol; echo -e "${GREEN}[OK]${NC} $*"; }
fail() { term_bol; echo -e "${RED}[FAIL]${NC} $*"; stty sane 2>/dev/null; exit 1; }
warn() { term_bol; echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { term_bol; echo ""; echo "=== $* ==="; }

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/vmlinux-5.10.bin"
KERNEL_PATH="/var/lib/microvms/kernels/vmlinux-5.10.bin"
BASE_ROOTFS="/var/lib/microvms/base/base-rootfs.ext4"
MOUNT_ROOT="/mnt/microvm-root"
SOCKET_TIMEOUT=15
VM_BOOT_WAIT=20

# When run non-interactively, fail fast if sudo would need a password
if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo. Run it from an interactive terminal so you can enter your password,"
  echo "or configure passwordless sudo for your user. Then run: $0"
  exit 1
fi

# --- Parse arguments ---
PROJECT="${PROJECT:-myproj}"
SSH_PORT="${SSH_PORT:-22240}"
SETUP_ONLY=false
NO_SETUP=false
TEARDOWN=false
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup-only) SETUP_ONLY=true; shift ;;
    --no-setup)    NO_SETUP=true; shift ;;
    --teardown)    TEARDOWN=true; shift ;;
    *)             POSITIONAL+=("$1"); shift ;;
  esac
done
if [[ ${#POSITIONAL[@]} -ge 1 ]]; then PROJECT="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then SSH_PORT="${POSITIONAL[1]}"; fi

# Resolve net scripts: prefer /usr/local/sbin, else env, else same directory as this script
if [[ -x /usr/local/sbin/microvm-net-up.sh ]] && [[ -x /usr/local/sbin/microvm-net-down.sh ]]; then
  MICROVM_NET_UP="/usr/local/sbin/microvm-net-up.sh"
  MICROVM_NET_DOWN="/usr/local/sbin/microvm-net-down.sh"
else
  MICROVM_NET_UP="${MICROVM_NET_UP:-$BUILD_DIR/microvm-net-up.sh}"
  MICROVM_NET_DOWN="${MICROVM_NET_DOWN:-$BUILD_DIR/microvm-net-down.sh}"
fi

# --- Prereq checks (Step 1, 2, 3) ---
step "Prereq checks (Steps 1–3)"

val=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)
if [[ "${val}" != "1" ]]; then
  fail "net.ipv4.ip_forward is not 1 (got: ${val}); complete Step 1 first"
fi
ok "sysctl net.ipv4.ip_forward = 1"

if ! (sudo firewall-cmd --list-ports 2>/dev/null || firewall-cmd --list-ports 2>/dev/null) | grep -q 20000; then
  fail "Firewall port range 20000-29999/tcp not listed; complete Step 1 first"
fi
ok "Firewall allows SSH port range"

if ! command -v firecracker &>/dev/null; then
  fail "firecracker not in PATH; complete Step 2 first (install to /usr/local/bin)"
fi
if ! command -v jailer &>/dev/null; then
  fail "jailer not in PATH; complete Step 2 first (install to /usr/local/bin)"
fi
firecracker --version &>/dev/null || fail "firecracker --version failed"
jailer --version &>/dev/null || fail "jailer --version failed"
ok "firecracker and jailer found and runnable"

if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
  warn "SELinux is Enforcing; chpasswd in chroot may fail. If password setup fails, run: sudo setenforce 0 (see Step04.md)"
fi

LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
if [[ -z "${LAN_IF}" ]]; then
  fail "No default route; complete Step 1/3 (ip route show default)"
fi
ok "LAN_IF=${LAN_IF}"

if [[ "$SETUP_ONLY" != true ]]; then
  if [[ ! -x "$MICROVM_NET_UP" ]] || [[ ! -x "$MICROVM_NET_DOWN" ]]; then
    fail "microvm-net-up or microvm-net-down not executable: ${MICROVM_NET_UP} / ${MICROVM_NET_DOWN}; complete Step 3"
  fi
  ok "Net scripts: ${MICROVM_NET_UP}, ${MICROVM_NET_DOWN}"

  # Optional 4.3 check: warn if net-up script doesn't look like /30
  if grep -q 'GUEST_IP=172\.31' "$MICROVM_NET_UP" 2>/dev/null || grep -q 'BLOCK + 1' "$MICROVM_NET_UP" 2>/dev/null; then
    ok "Net script appears to use /30 host addresses (4.3)"
  else
    warn "microvm-net-up.sh may not use valid /30 host addresses; see Step04.md section 4.3"
  fi
fi

# --- Phase 1: 4.1 Kernel (once) ---
step "4.1 Kernel"

if [[ ! -f "$KERNEL_PATH" ]] || [[ ! -s "$KERNEL_PATH" ]]; then
  echo "   Downloading kernel..."
  sudo mkdir -p /var/lib/microvms/kernels
  # Remove empty or partial file so wget or fallback can overwrite
  sudo rm -f "$KERNEL_PATH"
  sudo wget -q --timeout=60 -O "$KERNEL_PATH" "$KERNEL_URL" 2>/dev/null || true
  if [[ ! -s "$KERNEL_PATH" ]]; then
    fallback=""
    if [[ -r "${BUILD_DIR}/vmlinux-5.10.bin" ]]; then
      fallback="${BUILD_DIR}/vmlinux-5.10.bin"
    elif [[ -r "${HOME}/vmlinux-5.10.bin" ]]; then
      fallback="${HOME}/vmlinux-5.10.bin"
    else
      shopt -s nullglob
      candidates=("${BUILD_DIR}"/vmlinux*.bin "${HOME}"/vmlinux*.bin)
      shopt -u nullglob
      if [[ ${#candidates[@]} -ge 1 ]] && [[ -r "${candidates[0]}" ]]; then
        fallback="${candidates[0]}"
      fi
    fi
    if [[ -n "$fallback" ]]; then
      echo "   Using fallback kernel: $fallback"
      sudo cp "$fallback" "$KERNEL_PATH"
      sudo chmod 644 "$KERNEL_PATH"
      ok "Copied kernel from $fallback"
    else
      fail "Kernel download failed. Place a Firecracker-compatible kernel in the build directory next to this script (e.g. build/vmlinux-5.10.bin) or at $HOME/vmlinux-5.10.bin and re-run."
    fi
  else
    sudo chmod 644 "$KERNEL_PATH"
    ok "Downloaded $KERNEL_PATH"
  fi
else
  ok "Kernel already present: $KERNEL_PATH"
fi

out=$(file "$KERNEL_PATH" 2>/dev/null || true)
if ! echo "$out" | grep -qE 'ELF 64-bit LSB executable.*x86-64'; then
  fail "Kernel file check failed (expected ELF 64-bit x86-64): $out"
fi
ok "Kernel file type verified"

if [[ "$NO_SETUP" == true ]]; then
  if [[ ! -f "$KERNEL_PATH" ]]; then
    fail "NO_SETUP set but kernel missing at $KERNEL_PATH; run without --no-setup first"
  fi
  ok "Skipping setup (--no-setup)"
fi

# --- Phase 2: 4.2 Base rootfs (once) ---
if [[ "$NO_SETUP" != true ]] && [[ ! -f "$BASE_ROOTFS" ]]; then
  step "4.2 Base rootfs (create)"

  sudo mkdir -p /var/lib/microvms/base
  echo "   Creating 2GiB image..."
  sudo dd if=/dev/zero of="$BASE_ROOTFS" bs=1M count=2048 status=none
  sudo mkfs.ext4 -q "$BASE_ROOTFS"
  ok "Image created and formatted"

  step "4.2 Mount and install packages"
  sudo mkdir -p "$MOUNT_ROOT"
  sudo umount "$MOUNT_ROOT" 2>/dev/null || true
  sudo mount -o loop "$BASE_ROOTFS" "$MOUNT_ROOT"

  sudo dnf install --installroot="$MOUNT_ROOT" \
    --releasever=10 \
    --setopt=install_weak_deps=False \
    -y \
    almalinux-release \
    systemd \
    openssh-server \
    iproute \
    iputils \
    sudo \
    bash \
    coreutils \
    procps-ng \
    passwd \
    vim \
    tar \
    libstdc++ \
    curl \
    NetworkManager
  ok "Packages installed"

  step "4.2 Chroot configure (non-interactive)"
  # Ensure passwd/shadow exist and are writable (avoid chpasswd "cannot open" in chroot)
  sudo chmod 644 "$MOUNT_ROOT/etc/passwd" 2>/dev/null || true
  sudo chmod 600 "$MOUNT_ROOT/etc/shadow" 2>/dev/null || true
  if [[ ! -f "$MOUNT_ROOT/etc/passwd" ]] || [[ ! -s "$MOUNT_ROOT/etc/passwd" ]]; then
    echo 'root:x:0:0:root:/root:/bin/bash' | sudo tee "$MOUNT_ROOT/etc/passwd" > /dev/null
    sudo chmod 644 "$MOUNT_ROOT/etc/passwd"
  fi
  if [[ ! -f "$MOUNT_ROOT/etc/shadow" ]] || [[ ! -s "$MOUNT_ROOT/etc/shadow" ]]; then
    echo 'root:*:0:0:99999:7:::' | sudo tee "$MOUNT_ROOT/etc/shadow" > /dev/null
    sudo chmod 600 "$MOUNT_ROOT/etc/shadow"
  fi

  sudo mount --bind /dev "$MOUNT_ROOT/dev"
  sudo mount -t proc proc "$MOUNT_ROOT/proc"
  sudo mount -t sysfs sys "$MOUNT_ROOT/sys"

  DEV_PASS="${DEV_PASSWORD:-microvm}"
  sudo chroot "$MOUNT_ROOT" /bin/bash -s <<CHROOT_END
set -e
useradd -m -s /bin/bash dev 2>/dev/null || true
usermod -aG wheel dev
echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/eth0.nmconnection << 'NMEOF'
[connection]
id=eth0
type=ethernet
interface-name=eth0

[ipv4]
method=manual
addresses=172.31.12.1/30
gateway=172.31.12.0
dns=192.168.251.230;

[ipv6]
method=disabled
NMEOF
chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection
systemctl enable NetworkManager
systemctl enable sshd
echo microvm > /etc/hostname
CHROOT_END

  # Relabel /etc so chpasswd can write shadow (best-effort when SELinux is enforcing)
  sudo restorecon -R "$MOUNT_ROOT/etc" 2>/dev/null || true
  # Set passwords inside chroot (avoids chpasswd -R "failure while writing" to /etc/shadow on some systems)
  { echo "root:${DEV_PASS}"; echo "dev:${DEV_PASS}"; } | sudo chroot "$MOUNT_ROOT" chpasswd

  sudo umount "$MOUNT_ROOT/dev" "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys"
  sudo umount "$MOUNT_ROOT"
  ok "Base rootfs configured and unmounted"
elif [[ -f "$BASE_ROOTFS" ]]; then
  step "4.2 Base rootfs"
  ok "Base rootfs already exists: $BASE_ROOTFS"
fi

if [[ "$SETUP_ONLY" == true ]]; then
  echo ""
  echo -e "${GREEN}=== Setup only complete: kernel and base rootfs ready. Run without --setup-only to start a VM. ===${NC}"
  exit 0
fi

if [[ ! -f "$BASE_ROOTFS" ]]; then
  fail "Base rootfs not found at $BASE_ROOTFS; run without --no-setup first to create it"
fi

# --- Phase 3: 4.4 Per-project networking and rootfs ---
did_net_up=false
did_mount_project_root=false
cleanup_mount_root() {
  if [[ "${did_mount_project_root:-}" != true ]]; then
    return 0
  fi
  term_bol
  if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    sudo umount "$MOUNT_ROOT/dev" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT" 2>/dev/null || true
    if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
      sudo umount -l "$MOUNT_ROOT" 2>/dev/null || true
    fi
  fi
  did_mount_project_root=false
}
cleanup_net() {
  if [[ "${did_net_up:-}" == true ]] && [[ -n "${PROJECT:-}" ]] && [[ -n "${SSH_PORT:-}" ]] && [[ -n "${LAN_IF:-}" ]]; then
    sudo "$MICROVM_NET_DOWN" "$PROJECT" "$SSH_PORT" "$LAN_IF" 2>/dev/null || true
  fi
}
trap 'cleanup_mount_root; cleanup_net; stty sane 2>/dev/null' EXIT INT TERM

step "4.4.1 Bring up networking (${PROJECT}, port ${SSH_PORT})"

net_out=$(sudo "$MICROVM_NET_UP" "$PROJECT" "$SSH_PORT" "$LAN_IF" || true)
did_net_up=true
eval "$(echo "$net_out" | grep -E '^(HOST_IP|GUEST_IP)=')" || true
if [[ -z "${GUEST_IP:-}" ]] || [[ -z "${HOST_IP:-}" ]]; then
  fail "Could not parse HOST_IP/GUEST_IP from microvm-net-up output. Ensure script prints HOST_IP= and GUEST_IP= (Step 3 and 4.3). Output: $net_out"
fi
ok "GUEST_IP=${GUEST_IP} HOST_IP=${HOST_IP}"

step "4.4.2 Copy base rootfs and patch IPs"
# Unmount any existing mount at MOUNT_ROOT (e.g. leftover from a previous failed run)
if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
  sudo umount "$MOUNT_ROOT/dev" 2>/dev/null || true
  sudo umount "$MOUNT_ROOT" 2>/dev/null || true
  if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    sudo umount -l "$MOUNT_ROOT" 2>/dev/null || true
  fi
  if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    fail "Could not unmount ${MOUNT_ROOT}; free it manually (sudo umount -l ${MOUNT_ROOT}) and re-run"
  fi
fi
sudo mkdir -p "/var/lib/microvms/${PROJECT}"
sudo cp --reflink=auto "$BASE_ROOTFS" "/var/lib/microvms/${PROJECT}/rootfs.ext4"
sudo mount -o loop "/var/lib/microvms/${PROJECT}/rootfs.ext4" "$MOUNT_ROOT"
did_mount_project_root=true

# Set root and dev passwords on this project copy (so DEV_PASSWORD is used even if base was built earlier)
DEV_PASS="${DEV_PASSWORD:-microvm}"
sudo restorecon -R "$MOUNT_ROOT/etc" 2>/dev/null || true
sudo chmod 644 "$MOUNT_ROOT/etc/passwd" 2>/dev/null || true
sudo chmod 600 "$MOUNT_ROOT/etc/shadow" 2>/dev/null || true
# Run chpasswd inside chroot (avoids "cannot open /etc/passwd" with chpasswd -R on some systems)
sudo mount --bind /dev "$MOUNT_ROOT/dev"
{ echo "root:${DEV_PASS}"; echo "dev:${DEV_PASS}"; } | sudo chroot "$MOUNT_ROOT" chpasswd
sudo umount "$MOUNT_ROOT/dev"

sudo tee "$MOUNT_ROOT/etc/NetworkManager/system-connections/eth0.nmconnection" <<EOF
[connection]
id=eth0
type=ethernet
interface-name=eth0

[ipv4]
method=manual
addresses=${GUEST_IP}/30
gateway=${HOST_IP}
dns=192.168.251.230;

[ipv6]
method=disabled
EOF
sudo chmod 600 "$MOUNT_ROOT/etc/NetworkManager/system-connections/eth0.nmconnection"
sudo umount "$MOUNT_ROOT"
did_mount_project_root=false
ok "Project rootfs ready"

# --- Phase 4: 4.5 Start Firecracker ---
step "4.5.1 Start jailer"
echo ""

CHROOT_ROOT="/srv/jailer/firecracker/${PROJECT}/root"
FC_SOCK="${CHROOT_ROOT}/firecracker.socket"

# Kill any existing jailer and firecracker for this project, then remove chroot. Retry until jail dir is gone.
# (Orphaned firecracker processes can hold the chroot and prevent the new jailer from creating the socket.)
JAIL_DIR="/srv/jailer/firecracker/${PROJECT}"
for attempt in 1 2 3; do
  ( sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true ) 2>/dev/null
  ( sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true ) 2>/dev/null
  sleep 3
  if pgrep -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" &>/dev/null; then
    [[ $attempt -eq 3 ]] && fail "Jailer for ${PROJECT} still running after 3 pkill attempts; stop it manually (sudo pkill -9 -f jailer) and re-run"
    continue
  fi
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
  sudo rm -rf "$JAIL_DIR"
  sync
  if [[ ! -d "$JAIL_DIR" ]]; then
    break
  fi
  [[ $attempt -eq 3 ]] && fail "Jail directory ${JAIL_DIR} still exists after 3 cleanup attempts; something is holding it. Stop any jailer and re-run."
done
sudo mkdir -p /var/log/firecracker
LOG_FILE="/var/log/firecracker/${PROJECT}.log"
sudo truncate -s 0 "$LOG_FILE" 2>/dev/null || sudo touch "$LOG_FILE"

# Remove any stale jail so /dev/net/tun does not already exist (avoids "File exists" when running jailer)
( sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true ) 2>/dev/null
( sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true ) 2>/dev/null
sleep 2
sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
sudo rm -rf "/srv/jailer/firecracker/${PROJECT}"

# Probe: run jailer in foreground for 2s to capture startup errors (e.g. "File exists" for /dev/net/tun)
term_bol; echo "   Probing jailer startup (2s)..."
probe_exit=0
timeout 2 sudo /usr/local/bin/jailer --id "${PROJECT}" --exec-file /usr/local/bin/firecracker --uid 0 --gid 0 --chroot-base-dir /srv/jailer -- --api-sock /firecracker.socket --log-path /firecracker.log --level Debug 2>&1 | sudo tee "$LOG_FILE" >/dev/null || true
probe_exit=${PIPESTATUS[0]:-0}
stty sane 2>/dev/null || true

log_has_error() {
  sudo cat "$LOG_FILE" 2>/dev/null | grep -qiE 'error|failed|file exists|no such file'
}

start_jailer_background() {
  stty sane 2>/dev/null || true
  ( sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true ) 2>/dev/null
  ( sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true ) 2>/dev/null
  sleep 2
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
  sudo rm -rf "/srv/jailer/firecracker/${PROJECT}"
  sudo truncate -s 0 "$LOG_FILE" 2>/dev/null || true
  sudo bash -c "nohup /usr/local/bin/jailer --id '${PROJECT}' --exec-file /usr/local/bin/firecracker --uid 0 --gid 0 --chroot-base-dir /srv/jailer -- --api-sock /firecracker.socket --log-path /firecracker.log --level Debug >> '${LOG_FILE}' 2>&1 &"
  ok "Jailer started in background"
}

if [[ "$probe_exit" -eq 124 ]]; then
  # Timeout = jailer was still running; kill it, clean up, then start for real in background
  start_jailer_background
elif [[ "$probe_exit" -eq 0 ]] && ! log_has_error; then
  # Exit 0 and no error text in log: start in background (jailer can exit 0 in some cases)
  start_jailer_background
else
  echo ""
  echo "Jailer exited with code ${probe_exit}. Log output:"
  sudo cat "$LOG_FILE" 2>/dev/null || true
  fail "Jailer failed to start (exit ${probe_exit}). See log above. Common: 'File exists' for /dev/net/tun - ensure no other jailer is running (sudo pkill -9 -f jailer)."
fi

step "4.5.2 Wait for socket"
echo ""
elapsed=0
while [[ $elapsed -lt $SOCKET_TIMEOUT ]]; do
  if sudo test -S "$FC_SOCK"; then
    ok "Socket ready"
    break
  fi
  sleep 0.1
  elapsed=$((elapsed + 1))
done
if ! sudo test -S "$FC_SOCK"; then
  echo ""
  echo "Diagnostics:"
  echo "  Processes (jailer/firecracker for ${PROJECT}):"
  (sudo pgrep -af "jailer.*--id.*${PROJECT}" 2>/dev/null || true) | sed 's/^/    /'
  (sudo pgrep -af "firecracker.*--id.*${PROJECT}" 2>/dev/null || true) | sed 's/^/    /'
  echo "  Jail dir /srv/jailer/firecracker/${PROJECT}:"
  (sudo ls -la "/srv/jailer/firecracker/${PROJECT}" 2>/dev/null || echo "    (missing)") | sed 's/^/    /'
  if sudo test -d "${CHROOT_ROOT}"; then
    echo "  Firecracker log (chroot) ${CHROOT_ROOT}/firecracker.log:"
    (sudo tail -n 30 "${CHROOT_ROOT}/firecracker.log" 2>/dev/null || true) | sed 's/^/    /'
  fi
  echo "  Stdout/stderr log /var/log/firecracker/${PROJECT}.log:"
  (sudo tail -n 30 "/var/log/firecracker/${PROJECT}.log" 2>/dev/null || true) | sed 's/^/    /'
  fail "Socket did not appear after ${SOCKET_TIMEOUT}s; check logs above and run jailer manually to see errors"
fi

step "4.5.4 Bind-mount kernel and rootfs"
echo ""
sudo mkdir -p "${CHROOT_ROOT}/var/lib/microvms/kernels"
sudo mount --bind /var/lib/microvms/kernels "${CHROOT_ROOT}/var/lib/microvms/kernels"
sudo mkdir -p "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
sudo mount --bind "/var/lib/microvms/${PROJECT}" "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
ok "Bind mounts done"

step "4.5.5 Configure VM via API"
echo ""

api_put() {
  local path="$1"
  local body="$2"
  local tmp
  tmp=$(mktemp)
  local code
  code=$(sudo curl -s -w '%{http_code}' -o "$tmp" --unix-socket "$FC_SOCK" \
    -H "Content-Type: application/json" -X PUT "http://localhost${path}" -d "$body") || true
  [[ -z "${code}" ]] && code="000"
  if [[ "${code}" != 204 ]] && [[ "${code}" != 200 ]]; then
    term_bol; echo ""
    term_bol; echo "API error (${path}): HTTP ${code:-empty}"
    term_bol; echo "Response body: $(cat "$tmp" 2>/dev/null || echo '(none)')"
    rm -f "$tmp"
    fail "API PUT ${path} failed; see above. Logs: /var/log/firecracker/${PROJECT}.log and ${CHROOT_ROOT}/firecracker.log"
  fi
  rm -f "$tmp"
}

term_bol; echo "   PUT /machine-config..."
api_put /machine-config '{ "vcpu_count": 2, "mem_size_mib": 2048, "smt": false }'
# Boot args: console, reboot, panic, pci=off per Firecracker; clocksource=tsc tsc=reliable to prefer TSC
# and reduce RTC/CMOS (0x70/0x71) probing. If you still see "IO write @ 0x70:0x1 failed: MissingAddressRange",
# the pre-built kernel may probe legacy ports—use a Firecracker-built kernel (see Step04.md troubleshooting).
BOOT_ARGS='console=ttyS0 reboot=k panic=1 pci=off clocksource=tsc tsc=reliable'
term_bol; echo "   PUT /boot-source..."
api_put /boot-source "{\"kernel_image_path\": \"/var/lib/microvms/kernels/vmlinux-5.10.bin\", \"boot_args\": \"${BOOT_ARGS}\"}"
term_bol; echo "   PUT /drives/rootfs..."
api_put /drives/rootfs "{\"drive_id\": \"rootfs\", \"path_on_host\": \"/var/lib/microvms/${PROJECT}/rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}"
term_bol; echo "   PUT /network-interfaces/eth0..."
api_put /network-interfaces/eth0 "{\"iface_id\": \"eth0\", \"host_dev_name\": \"tap-${PROJECT}\"}"
term_bol; echo "   PUT /actions (InstanceStart)..."
api_put /actions '{ "action_type": "InstanceStart" }'
ok "VM started"

# --- Phase 5: Verification and optional teardown ---
step "4.6 Verification"

HOST_LAN_IP=$(ip -4 -o addr show "$LAN_IF" | awk '{print $4}' | cut -d/ -f1)
term_bol; echo "   HOST_LAN_IP=${HOST_LAN_IP} (use this for SSH from another machine)"
term_bol; echo "   Waiting ${VM_BOOT_WAIT}s for VM to boot..."
sleep "$VM_BOOT_WAIT"

if ping -c 2 -W 2 "${GUEST_IP}" &>/dev/null; then
  ok "VM responds to ping at ${GUEST_IP}"
else
  warn "VM did not respond to ping at ${GUEST_IP}; it may still be booting or NetworkManager not up. Try: ping -c 2 ${GUEST_IP}"
fi

DEV_PASS="${DEV_PASSWORD:-microvm}"
term_bol; echo ""
term_bol; echo "   To test from another machine on the LAN:"
term_bol; echo "     ssh -p ${SSH_PORT} dev@${HOST_LAN_IP}"
term_bol; echo "   (password: ${DEV_PASS})"
term_bol; echo "   Inside the VM: ip addr show eth0; ping -c 2 1.1.1.1"
term_bol; echo ""

if [[ "$TEARDOWN" == true ]]; then
  step "4.7 Teardown"
  sudo curl -s --unix-socket "$FC_SOCK" -H "Content-Type: application/json" \
    -X PUT http://localhost/actions -d '{ "action_type": "SendCtrlAltDel" }' || true
  sleep 3
  if sudo test -S "$FC_SOCK"; then
    sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true
    sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true
    sleep 1
  fi
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
  sudo rm -rf "/srv/jailer/firecracker/${PROJECT}"
  sudo "$MICROVM_NET_DOWN" "$PROJECT" "$SSH_PORT" "$LAN_IF"
  did_net_up=false
  trap - EXIT INT TERM
  ok "VM stopped, bind mounts unmounted, jail removed, networking torn down"
fi

# Success without --teardown: leave VM and net up; do not run cleanup_net on exit
did_net_up=false

term_bol; echo ""
term_bol; echo -e "${GREEN}=== Step 4 complete: microVM ${PROJECT} is up. ===${NC}"
term_bol; echo "   Logs: sudo tail -f /var/log/firecracker/${PROJECT}.log"
term_bol; echo "   Logs: sudo tail -f ${CHROOT_ROOT}/firecracker.log"
