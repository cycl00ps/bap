#!/usr/bin/env bash
# List currently running Firecracker microVMs (by project id).
# Usage: ./microvm-list-all.sh [-q]
#   -q  Quiet: print only project ids, one per line (for scripting).
set -euo pipefail

QUIET=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q) QUIET=true; shift ;;
    *)  echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

list_running() {
  ps -eo args 2>/dev/null | grep '[f]irecracker' | grep -- '--id' | sed -n 's/.*--id[= ]\([^ ]*\).*/\1/p'
}

mapfile -t ids < <(list_running)

if [[ "${QUIET}" == true ]]; then
  printf '%s\n' "${ids[@]}"
  exit 0
fi

if [[ ${#ids[@]} -eq 0 ]]; then
  echo "No running microVMs."
else
  echo "Running microVMs:"
  for id in "${ids[@]}"; do echo "  $id"; done
  echo "Total: ${#ids[@]}"
fi
