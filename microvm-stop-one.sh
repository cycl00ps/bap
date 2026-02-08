#!/usr/bin/env bash
# Stop a single Firecracker microVM: list running, select interactively, or kill by project id.
# Usage: ./microvm-stop-one.sh [--list] [--port PORT] [PROJECT]
#   --list       List running microVM project ids and exit.
#   --port PORT  SSH port used for this project (for net teardown). Default: 22240.
#   PROJECT      Project id to stop (e.g. myproj). If omitted and not --list, show menu to select.
# Prerequisite: microvm-net-down.sh in /usr/local/sbin or in the same directory as this script (build/).
set -euo pipefail

# Ensure output starts at column 1 (same as run-step04.sh)
term_bol() { printf '\n\r\033[K'; }
trap 'stty sane 2>/dev/null' EXIT INT TERM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT="${SSH_PORT:-22240}"
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l) LIST_ONLY=true; shift ;;
    --port)    SSH_PORT="$2"; shift 2 ;;
    -*)        term_bol; echo "Unknown option: $1" >&2; exit 1 ;;
    *)         PROJECT="$1"; shift ;;
  esac
done

if [[ -x /usr/local/sbin/microvm-net-down.sh ]]; then
  MICROVM_NET_DOWN="/usr/local/sbin/microvm-net-down.sh"
else
  MICROVM_NET_DOWN="${MICROVM_NET_DOWN:-$SCRIPT_DIR/microvm-net-down.sh}"
fi

LAN_IF=$(ip route show default 2>/dev/null | awk '/^default/ {print $5}')
[[ -z "${LAN_IF}" ]] && LAN_IF="auto"

# Output running microVM ids (one per line)
list_running() {
  ps -eo args 2>/dev/null | grep '[f]irecracker' | grep -- '--id' | sed -n 's/.*--id[= ]\([^ ]*\).*/\1/p'
}

# Full teardown for one project. Run all teardown commands in a subshell with output discarded
# so "Killed" and net-down script messages never reach the terminal; only our echoes do.
do_teardown() {
  local proj="$1"
  local chroot_root="/srv/jailer/firecracker/${proj}/root"
  local sock="${chroot_root}/firecracker.socket"

  term_bol; echo "Stopping microVM: ${proj}"
  (
    sudo curl -s --unix-socket "$sock" -H "Content-Type: application/json" \
      -X PUT http://localhost/actions -d '{ "action_type": "SendCtrlAltDel" }' 2>/dev/null || true
    sleep 3
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

if [[ "${LIST_ONLY}" == true ]]; then
  mapfile -t running < <(list_running)
  if [[ ${#running[@]} -eq 0 ]]; then
    term_bol; echo "No running microVMs."
  else
    term_bol; echo "Running microVMs:"
    for id in "${running[@]}"; do term_bol; echo "  $id"; done
    term_bol; echo "Total: ${#running[@]}"
  fi
  exit 0
fi

if [[ -n "${PROJECT:-}" ]]; then
  if ! list_running | grep -qx "$PROJECT"; then
    term_bol; echo "No running microVM with project id: ${PROJECT}" >&2
    term_bol; echo "Running ids:" >&2
    list_running | sed 's/^/  /' >&2
    exit 1
  fi
  do_teardown "$PROJECT"
  exit 0
fi

# Interactive: show numbered list and let user choose
mapfile -t ids < <(list_running)
if [[ ${#ids[@]} -eq 0 ]]; then
  term_bol; echo "No running microVMs."
  exit 0
fi

term_bol; echo "Running microVMs:"
for i in "${!ids[@]}"; do
  term_bol; echo "  $((i+1))) ${ids[$i]}"
done
term_bol; echo "  0) Cancel"
read -rp "Select number to stop (0 to cancel): " choice
stty sane 2>/dev/null || true
if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
  term_bol; echo "Cancelled."
  exit 0
fi
if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#ids[@]} ]]; then
  do_teardown "${ids[$((choice-1))]}"
else
  term_bol; echo "Invalid selection." >&2
  exit 1
fi
