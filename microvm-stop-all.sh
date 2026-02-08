#!/usr/bin/env bash
# Stop all running Firecracker microVMs: graceful teardown, unmount, net-down per project.
# Usage: ./microvm-stop-all.sh [--port PORT]
#   --port PORT  SSH port used for projects (for net teardown). Default: 22240.
# Prerequisite: microvm-net-down.sh in /usr/local/sbin or in the same directory as this script (build/).
set -euo pipefail

# Ensure output starts at column 1 (same as run-step04.sh)
term_bol() { printf '\n\r\033[K'; }
trap 'stty sane 2>/dev/null' EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT="${SSH_PORT:-22240}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) SSH_PORT="$2"; shift 2 ;;
    -*)     term_bol; echo "Unknown option: $1" >&2; exit 1 ;;
    *)      shift ;;
  esac
done

if [[ -x /usr/local/sbin/microvm-net-down.sh ]]; then
  MICROVM_NET_DOWN="/usr/local/sbin/microvm-net-down.sh"
else
  MICROVM_NET_DOWN="${MICROVM_NET_DOWN:-$SCRIPT_DIR/microvm-net-down.sh}"
fi

LAN_IF=$(ip route show default 2>/dev/null | awk '/^default/ {print $5}')
[[ -z "${LAN_IF}" ]] && LAN_IF="auto"

list_running() {
  ps -eo args 2>/dev/null | grep '[f]irecracker' | grep -- '--id' | sed -n 's/.*--id[= ]\([^ ]*\).*/\1/p'
}

# Run all teardown commands in a subshell with output discarded so "Killed" and net-down
# script messages never reach the terminal; only our echoes do.
do_teardown() {
  local proj="$1"
  local chroot_root="/srv/jailer/firecracker/${proj}/root"
  local sock="${chroot_root}/firecracker.socket"

  term_bol; echo "Stopping microVM: ${proj}"
  (
    sudo curl -s --unix-socket "$sock" -H "Content-Type: application/json" \
      -X PUT http://localhost/actions -d '{ "action_type": "SendCtrlAltDel" }' 2>/dev/null || true
    sleep 2
    sudo pkill -9 -f "firecracker.*--id.*${proj}" 2>/dev/null || true
    sudo pkill -9 -f "jailer.*--id.*${proj}" 2>/dev/null || true
    sleep 1
    sudo umount "${chroot_root}/var/lib/microvms/kernels" 2>/dev/null || true
    sudo umount "${chroot_root}/var/lib/microvms/${proj}" 2>/dev/null || true
    sudo rm -rf "/srv/jailer/firecracker/${proj}"
    if [[ -x "$MICROVM_NET_DOWN" ]]; then
      sudo "$MICROVM_NET_DOWN" "$proj" "$SSH_PORT" "$LAN_IF" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1
  stty sane 2>/dev/null || true
  term_bol; echo "Done: ${proj} stopped."
}

mapfile -t ids < <(list_running)
if [[ ${#ids[@]} -eq 0 ]]; then
  term_bol; echo "No running microVMs."
  exit 0
fi

term_bol; echo "Stopping ${#ids[@]} microVM(s): ${ids[*]}"
for proj in "${ids[@]}"; do
  do_teardown "$proj"
done
term_bol; echo "All microVMs stopped."
