#!/usr/bin/env bash
# Run Step 5 (build/Step05.md): secure base (key-only + first-run) and/or launch with injection.
# Usage:
#   ./build/run-step05.sh --secure-base
#       Apply key-only SSH and first-run service to the base image (run after run-step04.sh --setup-only).
#   ./build/run-step05.sh [PROJECT] [SSH_PORT] [--teardown]
#       Create project rootfs from secured base, inject project.env and optional bootstrap.d, start VM.
#       Set DEV_SSH_KEY (required), REPO_URL, GIT_REF, DEV_USER, FIRST_RUN_SCRIPT, BOOTSTRAP_D_DIR as needed.
# Prerequisite: Step 4 done; for --secure-base the base image must exist. For launch, base must be secured first.
# Does not modify run-step04.sh or existing .sh scripts.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
term_bol() { printf '\n\r\033[K'; }
ok()  { term_bol; echo -e "${GREEN}[OK]${NC} $*"; }
fail() { term_bol; echo -e "${RED}[FAIL]${NC} $*"; stty sane 2>/dev/null; exit 1; }
warn() { term_bol; echo -e "${YELLOW}[WARN]${NC} $*"; }
step() { term_bol; echo ""; echo "=== $* ==="; }

BUILD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_ROOTFS="/var/lib/microvms/base/base-rootfs.ext4"
MOUNT_ROOT="/mnt/microvm-root"
KERNEL_PATH="/var/lib/microvms/kernels/vmlinux-5.10.bin"
SOCKET_TIMEOUT=15
VM_BOOT_WAIT=20

if [[ ! -t 0 ]] && ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo. Run from an interactive terminal or configure passwordless sudo."
  exit 1
fi

SECURE_BASE=false
TEARDOWN=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --secure-base) SECURE_BASE=true; shift ;;
    --teardown)    TEARDOWN=true; shift ;;
    *)             POSITIONAL+=("$1"); shift ;;
  esac
done
PROJECT="${PROJECT:-myproj}"
SSH_PORT="${SSH_PORT:-22240}"
[[ ${#POSITIONAL[@]} -ge 1 ]] && PROJECT="${POSITIONAL[0]}"
[[ ${#POSITIONAL[@]} -ge 2 ]] && SSH_PORT="${POSITIONAL[1]}"

if [[ -x /usr/local/sbin/microvm-net-up.sh ]] && [[ -x /usr/local/sbin/microvm-net-down.sh ]]; then
  MICROVM_NET_UP="/usr/local/sbin/microvm-net-up.sh"
  MICROVM_NET_DOWN="/usr/local/sbin/microvm-net-down.sh"
else
  MICROVM_NET_UP="${MICROVM_NET_UP:-$BUILD_DIR/microvm-net-up.sh}"
  MICROVM_NET_DOWN="${MICROVM_NET_DOWN:-$BUILD_DIR/microvm-net-down.sh}"
fi

# --- Mode: secure base only ---
if [[ "$SECURE_BASE" == true ]]; then
  step "5.2 Secure base (key-only + first-run)"
  [[ -f "$BASE_ROOTFS" ]] || fail "Base rootfs not found at $BASE_ROOTFS; run run-step04.sh --setup-only first"
  if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    sudo umount "$MOUNT_ROOT/dev" "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT" 2>/dev/null || true
  fi
  sudo mkdir -p "$MOUNT_ROOT"
  sudo mount -o loop "$BASE_ROOTFS" "$MOUNT_ROOT"
  if [[ -f "$MOUNT_ROOT/usr/local/sbin/project-bootstrap.sh" ]]; then
    ok "Base already secured"
    sudo umount "$MOUNT_ROOT"
    exit 0
  fi
  sudo mount --bind /dev "$MOUNT_ROOT/dev"
  sudo mount -t proc proc "$MOUNT_ROOT/proc"
  sudo mount -t sysfs sys "$MOUNT_ROOT/sys"
  sudo chroot "$MOUNT_ROOT" /bin/bash -s <<'SECURE_END'
set -e
sed -i -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' -e 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
passwd -l root
dnf install -y git 2>/dev/null || true
mkdir -p /etc/bootstrap.d
cat > /usr/local/sbin/project-bootstrap.sh <<'BOOT'
#!/usr/bin/env bash
set -euo pipefail
SENTINEL="/var/lib/first-run.done"
[[ -f "$SENTINEL" ]] && exit 0
[[ -f /etc/project.env ]] || { echo "Missing /etc/project.env"; exit 1; }
source /etc/project.env
DEV_USER="${DEV_USER:-dev}"
PROJECT="${PROJECT:-}"
WORK_DIR="${WORK_DIR:-/work}"
id "$DEV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV_USER"
install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "/home/$DEV_USER/.ssh"
[[ -n "${DEV_SSH_KEY:-}" ]] && { echo "$DEV_SSH_KEY" > "/home/$DEV_USER/.ssh/authorized_keys"; chmod 600 "/home/$DEV_USER/.ssh/authorized_keys"; }
chown -R "$DEV_USER:$DEV_USER" "/home/$DEV_USER/.ssh"
install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "$WORK_DIR"
if [[ -n "${REPO_URL:-}" ]] && [[ -n "${PROJECT:-}" ]]; then
  [[ ! -d "$WORK_DIR/$PROJECT/.git" ]] && sudo -u "$DEV_USER" git clone "$REPO_URL" "$WORK_DIR/$PROJECT"
  cd "$WORK_DIR/$PROJECT" && sudo -u "$DEV_USER" git fetch --all --prune && sudo -u "$DEV_USER" git checkout -f "${GIT_REF:-HEAD}"
fi
for f in /etc/bootstrap.d/*.sh; do [[ -f "$f" ]] && [[ -x "$f" ]] && "$f" || true; done
touch "$SENTINEL"
BOOT
chmod +x /usr/local/sbin/project-bootstrap.sh
cat > /etc/systemd/system/project-bootstrap.service <<'UNIT'
[Unit]
Description=Project bootstrap (first-run)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/project-bootstrap.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable project-bootstrap.service
SECURE_END
  sudo umount "$MOUNT_ROOT/dev" "$MOUNT_ROOT/proc" "$MOUNT_ROOT/sys"
  sudo umount "$MOUNT_ROOT"
  ok "Base secured: key-only SSH, first-run service, git installed"
  echo ""; echo -e "${GREEN}=== Run with PROJECT and DEV_SSH_KEY (and optional REPO_URL, GIT_REF, FIRST_RUN_SCRIPT) to launch. ===${NC}"
  exit 0
fi

# --- Launch with injection ---
step "Prereq checks"
[[ -f "$BASE_ROOTFS" ]] || fail "Base rootfs not found; run run-step04.sh --setup-only first"
sudo mount -o loop "$BASE_ROOTFS" "$MOUNT_ROOT" 2>/dev/null || true
[[ -f "$MOUNT_ROOT/usr/local/sbin/project-bootstrap.sh" ]] || fail "Base not secured; run: $0 --secure-base"
sudo umount "$MOUNT_ROOT" 2>/dev/null || true
[[ -n "${DEV_SSH_KEY:-}" ]] || fail "Set DEV_SSH_KEY (public key) for key-only launch"
[[ -f "$KERNEL_PATH" ]] || fail "Kernel not found at $KERNEL_PATH"
[[ -x "$MICROVM_NET_UP" ]] && [[ -x "$MICROVM_NET_DOWN" ]] || fail "microvm-net-up/down not found"
LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
[[ -n "$LAN_IF" ]] || fail "No default route"
ok "Prereqs OK"

did_net_up=false
did_mount=false
cleanup_mount() {
  if [[ "$did_mount" == true ]] && mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
    sudo umount "$MOUNT_ROOT/dev" 2>/dev/null || true
    sudo umount "$MOUNT_ROOT" 2>/dev/null || true
  fi
  did_mount=false
}
cleanup_net() {
  [[ "$did_net_up" != true ]] && return 0
  [[ -n "${PROJECT:-}" ]] && [[ -n "${SSH_PORT:-}" ]] && [[ -n "${LAN_IF:-}" ]] && sudo "$MICROVM_NET_DOWN" "$PROJECT" "$SSH_PORT" "$LAN_IF" 2>/dev/null || true
}
trap 'cleanup_mount; cleanup_net; stty sane 2>/dev/null' EXIT INT TERM

step "5.3 Networking and project rootfs (injection)"
net_out=$(sudo "$MICROVM_NET_UP" "$PROJECT" "$SSH_PORT" "$LAN_IF" || true)
did_net_up=true
eval "$(echo "$net_out" | grep -E '^(HOST_IP|GUEST_IP)=')" || true
[[ -n "${GUEST_IP:-}" ]] && [[ -n "${HOST_IP:-}" ]] || fail "Could not parse HOST_IP/GUEST_IP from microvm-net-up"
ok "GUEST_IP=${GUEST_IP} HOST_IP=${HOST_IP}"

if mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
  sudo umount "$MOUNT_ROOT/dev" 2>/dev/null || true
  sudo umount "$MOUNT_ROOT" 2>/dev/null || true
fi
sudo mkdir -p "/var/lib/microvms/${PROJECT}"
sudo cp --reflink=auto "$BASE_ROOTFS" "/var/lib/microvms/${PROJECT}/rootfs.ext4"
sudo mount -o loop "/var/lib/microvms/${PROJECT}/rootfs.ext4" "$MOUNT_ROOT"
did_mount=true

escape_sq() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }
DEV_USER_INJECT="${DEV_USER:-dev}"
sudo tee "$MOUNT_ROOT/etc/project.env" >/dev/null <<ENVEOF
DEV_USER='$(escape_sq "$DEV_USER_INJECT")'
PROJECT='$(escape_sq "$PROJECT")'
WORK_DIR=/work
REPO_URL='$(escape_sq "${REPO_URL:-}")'
GIT_REF='$(escape_sq "${GIT_REF:-HEAD}")'
DEV_SSH_KEY='$(escape_sq "${DEV_SSH_KEY:-}")'
ENVEOF
sudo chmod 644 "$MOUNT_ROOT/etc/project.env"
[[ -n "${FIRST_RUN_SCRIPT:-}" ]] && [[ -f "$FIRST_RUN_SCRIPT" ]] && sudo mkdir -p "$MOUNT_ROOT/etc/bootstrap.d" && sudo cp "$FIRST_RUN_SCRIPT" "$MOUNT_ROOT/etc/bootstrap.d/99-user-bootstrap.sh" && sudo chmod 700 "$MOUNT_ROOT/etc/bootstrap.d/99-user-bootstrap.sh" && ok "Injected $FIRST_RUN_SCRIPT"
if [[ -n "${BOOTSTRAP_D_DIR:-}" ]] && [[ -d "$BOOTSTRAP_D_DIR" ]]; then
  sudo mkdir -p "$MOUNT_ROOT/etc/bootstrap.d"
  for f in "$BOOTSTRAP_D_DIR"/*.sh; do [[ -f "$f" ]] || continue; b=$(basename "$f"); sudo cp "$f" "$MOUNT_ROOT/etc/bootstrap.d/$b"; sudo chmod 700 "$MOUNT_ROOT/etc/bootstrap.d/$b"; done
  ok "Injected bootstrap.d from $BOOTSTRAP_D_DIR"
fi

sudo tee "$MOUNT_ROOT/etc/NetworkManager/system-connections/eth0.nmconnection" >/dev/null <<EOF
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
did_mount=false
ok "Project rootfs ready (key-only, first-run will configure guest)"

CHROOT_ROOT="/srv/jailer/firecracker/${PROJECT}/root"
FC_SOCK="${CHROOT_ROOT}/firecracker.socket"
JAIL_DIR="/srv/jailer/firecracker/${PROJECT}"
LOG_FILE="/var/log/firecracker/${PROJECT}.log"

step "Start jailer and VM"
for attempt in 1 2 3; do
  sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true
  sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true
  sleep 2
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
  sudo rm -rf "$JAIL_DIR"
  [[ ! -d "$JAIL_DIR" ]] && break
  [[ $attempt -eq 3 ]] && fail "Jail dir still exists"
done
sudo mkdir -p /var/log/firecracker
sudo truncate -s 0 "$LOG_FILE" 2>/dev/null || sudo touch "$LOG_FILE"
timeout 2 sudo /usr/local/bin/jailer --id "${PROJECT}" --exec-file /usr/local/bin/firecracker --uid 0 --gid 0 --chroot-base-dir /srv/jailer -- --api-sock /firecracker.socket --log-path /firecracker.log --level Debug >> "$LOG_FILE" 2>&1 || true
stty sane 2>/dev/null || true
sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true
sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true
sleep 2
sudo rm -rf "$JAIL_DIR"
sudo nohup /usr/local/bin/jailer --id "${PROJECT}" --exec-file /usr/local/bin/firecracker --uid 0 --gid 0 --chroot-base-dir /srv/jailer -- --api-sock /firecracker.socket --log-path /firecracker.log --level Debug >> "$LOG_FILE" 2>&1 &
elapsed=0
while [[ $elapsed -lt $SOCKET_TIMEOUT ]]; do sudo test -S "$FC_SOCK" 2>/dev/null && break; sleep 0.1; elapsed=$((elapsed+1)); done
sudo test -S "$FC_SOCK" || fail "Socket did not appear; check $LOG_FILE"
ok "Socket ready"

sudo mkdir -p "${CHROOT_ROOT}/var/lib/microvms/kernels" "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
sudo mount --bind /var/lib/microvms/kernels "${CHROOT_ROOT}/var/lib/microvms/kernels"
sudo mount --bind "/var/lib/microvms/${PROJECT}" "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
api_put() {
  local path="$1" body="$2" tmp code
  tmp=$(mktemp)
  code=$(sudo curl -s -w '%{http_code}' -o "$tmp" --unix-socket "$FC_SOCK" -H "Content-Type: application/json" -X PUT "http://localhost${path}" -d "$body") || true
  [[ "${code}" == 204 || "${code}" == 200 ]] || { cat "$tmp"; rm -f "$tmp"; fail "API ${path} failed: ${code}"; }
  rm -f "$tmp"
}
BOOT_ARGS='console=ttyS0 reboot=k panic=1 pci=off clocksource=tsc tsc=reliable'
api_put /machine-config '{ "vcpu_count": 2, "mem_size_mib": 2048, "smt": false }'
api_put /boot-source "{\"kernel_image_path\": \"/var/lib/microvms/kernels/vmlinux-5.10.bin\", \"boot_args\": \"${BOOT_ARGS}\"}"
api_put /drives/rootfs "{\"drive_id\": \"rootfs\", \"path_on_host\": \"/var/lib/microvms/${PROJECT}/rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}"
api_put /network-interfaces/eth0 "{\"iface_id\": \"eth0\", \"host_dev_name\": \"tap-${PROJECT}\"}"
api_put /actions '{ "action_type": "InstanceStart" }'
ok "VM started"

step "Verification"
HOST_LAN_IP=$(ip -4 -o addr show "$LAN_IF" | awk '{print $4}' | cut -d/ -f1)
term_bol; echo "   HOST_LAN_IP=${HOST_LAN_IP}"
sleep "$VM_BOOT_WAIT"
ping -c 2 -W 2 "${GUEST_IP}" &>/dev/null && ok "VM responds at ${GUEST_IP}" || warn "VM may still be booting: ping ${GUEST_IP}"
term_bol; echo "   ssh -p ${SSH_PORT} ${DEV_USER_INJECT}@${HOST_LAN_IP}  (key-only; first-run configures guest)"
term_bol; echo ""

if [[ "$TEARDOWN" == true ]]; then
  step "Teardown"
  sudo curl -s --unix-socket "$FC_SOCK" -H "Content-Type: application/json" -X PUT http://localhost/actions -d '{ "action_type": "SendCtrlAltDel" }' || true
  sleep 3
  sudo pkill -9 -f "/usr/local/bin/jailer.*--id.*${PROJECT}.*--exec-file" 2>/dev/null || true
  sudo pkill -9 -f "firecracker.*--id.*${PROJECT}" 2>/dev/null || true
  sleep 1
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/kernels" 2>/dev/null || true
  sudo umount "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}" 2>/dev/null || true
  sudo rm -rf "$JAIL_DIR"
  sudo "$MICROVM_NET_DOWN" "$PROJECT" "$SSH_PORT" "$LAN_IF"
  did_net_up=false
  trap - EXIT INT TERM
  ok "VM stopped, networking torn down"
fi
did_net_up=false
term_bol; echo -e "${GREEN}=== Step 5 complete: microVM ${PROJECT} is up (key-only). ===${NC}"
term_bol; echo "   Logs: sudo tail -f $LOG_FILE"
