#!/usr/bin/env bash
# Run all steps from build/Step02.md: install Firecracker + jailer, verify, sanity-check.
# Usage: bash build/run-step02.sh   or   ./build/run-step02.sh
# Optional: FC_VERSION=v1.14.1 to pin a version (otherwise uses latest from GitHub API).
# Prerequisite: non-root user with sudo.

set -e
set -u

# --- 2.1 Create directory layout ---
echo "2.1 Creating directory layout..."
sudo mkdir -p \
  /var/lib/microvms/{kernels,base} \
  /srv/jailer \
  /usr/local/bin
sudo chmod 755 /var/lib/microvms /srv/jailer

# --- 2.2 Download Firecracker binaries ---
# Use a dedicated temp dir for download/extract/cleanup.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
cd "$WORK_DIR"

echo "2.2 Downloading Firecracker binaries..."
if [[ -n "${FC_VERSION:-}" ]]; then
  # Option B: pinned version from environment
  ARCH=$(uname -m)
  echo "   Using pinned FC_VERSION=$FC_VERSION ARCH=$ARCH"
else
  # Option A: latest from GitHub API
  FC_VERSION=$(curl -sL https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  ARCH=$(uname -m)
  echo "   Using latest FC_VERSION=$FC_VERSION ARCH=$ARCH"
fi

wget -qO firecracker.tgz \
  "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"

echo "2.2 Extracting..."
tar -xzf firecracker.tgz

echo "2.2 Installing binaries to /usr/local/bin..."
sudo install -m 755 "release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" /usr/local/bin/firecracker
sudo install -m 755 "release-${FC_VERSION}-${ARCH}/jailer-${FC_VERSION}-${ARCH}" /usr/local/bin/jailer

echo "2.2 Cleanup..."
rm -rf firecracker.tgz "release-${FC_VERSION}-${ARCH}"
cd - >/dev/null
# Remove WORK_DIR from trap so we don't double-remove; dir is already cleaned.
trap - EXIT
rm -rf "$WORK_DIR"

# --- 2.3 Verify binaries ---
echo "2.3 Verifying binaries..."
firecracker --version
jailer --version
firecracker --version | grep -q . || { echo "firecracker --version produced no output"; exit 1; }
jailer --version | grep -q . || { echo "jailer --version produced no output"; exit 1; }

# --- 2.4 Sanity check: Firecracker starts and API responds ---
echo "2.4 Sanity check: starting Firecracker and probing API..."
sudo rm -f /tmp/fc-test.sock
sudo /usr/local/bin/firecracker --api-sock /tmp/fc-test.sock &
FC_PID=$!
cleanup_fc() {
  sudo kill "$FC_PID" 2>/dev/null || true
  sudo rm -f /tmp/fc-test.sock
}
trap cleanup_fc EXIT INT TERM

echo "   Waiting for Firecracker to listen..."
sleep 2
response=$(sudo curl -s --unix-socket /tmp/fc-test.sock http://localhost/ || true)
# Newer Firecracker returns VM info on GET /; older returns {"error":"Invalid request method"}
if echo "$response" | grep -q 'Invalid request method'; then
  echo "   API responded as expected (invalid method): $response"
elif echo "$response" | grep -q '"app_name":"Firecracker"'; then
  echo "   API responded as expected (VM info): $response"
else
  echo "   Unexpected API response: $response"
  exit 1
fi
trap - EXIT INT TERM
cleanup_fc

# --- 2.6 Verification checklist ---
echo "2.6 Verification checklist..."
which firecracker
which jailer
firecracker --version
ls /srv/jailer

echo "Step02 complete: Firecracker and jailer installed and verified."
