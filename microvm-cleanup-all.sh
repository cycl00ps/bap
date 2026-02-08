#!/usr/bin/env bash
# Remove all local microVM images and runtime state so you can start fresh.
# Stops all running microVMs, unmounts bind/loop mounts, deletes kernel, base
# rootfs, and per-project rootfs under /var/lib/microvms/, and removes jailer
# chroots under /srv/jailer/firecracker/.
#
# Usage: ./microvm-cleanup-all.sh [--port PORT] [--dry-run]
#   --port PORT   SSH port used for net teardown (default: 22240). Passed to microvm-stop-all.sh.
#   --dry-run     Print what would be done without making changes.
#
# Prerequisite: microvm-net-down.sh in /usr/local/sbin or in the build directory (see microvm-stop-all.sh).
# After running: re-run run-step04.sh to re-download kernel and recreate base + project images.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

term_bol() { printf '\n\r\033[K'; }
step() { term_bol; echo ""; echo "=== $* ==="; }
ok()  { term_bol; echo -e "${GREEN}[OK]${NC} $*"; }
warn() { term_bol; echo -e "${YELLOW}[WARN]${NC} $*"; }
trap 'stty sane 2>/dev/null' EXIT INT TERM

SSH_PORT="${SSH_PORT:-22240}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)   SSH_PORT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      term_bol
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    -*) term_bol; echo "Unknown option: $1" >&2; exit 1 ;;
    *)  shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

step "1. Stop all running microVMs"
if [[ "$DRY_RUN" == true ]]; then
  echo "  [dry-run] would run: $SCRIPT_DIR/microvm-stop-all.sh --port $SSH_PORT"
else
  export SSH_PORT
  "$SCRIPT_DIR/microvm-stop-all.sh" --port "$SSH_PORT"
  ok "All microVMs stopped."
fi

step "2. Unmount bind mounts and loop mount"
RUN sudo umount /srv/jailer/firecracker/*/root/var/lib/microvms/kernels 2>/dev/null || true
RUN sudo umount /srv/jailer/firecracker/*/root/var/lib/microvms/* 2>/dev/null || true
RUN sudo umount /mnt/microvm-root 2>/dev/null || true
ok "Unmounts done."

step "3. Remove microVM images under /var/lib/microvms/"
RUN sudo rm -f /var/lib/microvms/*/rootfs.ext4
RUN sudo rm -f /var/lib/microvms/base/base-rootfs.ext4
RUN sudo rm -f /var/lib/microvms/kernels/vmlinux-5.10.bin
ok "Images removed (per-project rootfs, base rootfs, kernel)."

step "4. Remove jailer chroots"
RUN sudo rm -rf /srv/jailer/firecracker/*
ok "Jailer chroots removed."

term_bol
echo -e "${GREEN}Cleanup complete. Run run-step04.sh to start fresh.${NC}"
