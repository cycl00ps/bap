# STEP 5 — Secure access + metadata-driven bootstrapping

**Prerequisite:** Step 4 done; base image exists (e.g. after `run-step04.sh --setup-only`). Existing scripts (run-step04.sh, microvm-net-up/down) are not modified; Step 5 is implemented in **run-step05.sh**.

**Goals:**

- No password SSH: key-based auth only; root locked.
- Project-specific metadata injected at first boot.
- Deterministic, repeatable VM startup.

**Contract:**

- **`/etc/project.env`** — Written by the host when creating the project rootfs. Sourced by the first-run script and tools. Required for key-only launch.
- **`/etc/bootstrap.d/*.sh`** — Optional. User scripts copied by the host; first-run runs them after core setup (user, keys, repo).

---

## 5.1 Disable passwords inside the guest (key-only)

Mount the base image and chroot:

```bash
sudo mount -o loop /var/lib/microvms/base/base-rootfs.ext4 /mnt/microvm-root
sudo chroot /mnt/microvm-root
```

Edit SSH config:

```bash
sed -i \
  -e 's/^#PasswordAuthentication yes/PasswordAuthentication no/' \
  -e 's/^#PermitRootLogin.*/PermitRootLogin no/' \
  /etc/ssh/sshd_config
```

Lock root password:

```bash
passwd -l root
```

Exit and unmount:

```bash
exit
sudo umount /mnt/microvm-root
```

From now on: SSH key only.  
**Or use:** `./build/run-step05.sh --secure-base` to apply key-only plus the first-run service and git in one go (see 5.5).

---

## 5.2 Project metadata: `/etc/project.env`

The host injects one file at boot:

**`/etc/project.env`**

This is the contract between:

- host launcher (run-step05.sh)
- guest bootstrap (first-run service)
- coding agent / tools

Variables (set by run-step05.sh from env): `DEV_USER`, `PROJECT`, `WORK_DIR`, `REPO_URL`, `GIT_REF`, `DEV_SSH_KEY`.

---

## 5.3 Add the project bootstrap service (guest)

Mount base image again:

```bash
sudo mount -o loop /var/lib/microvms/base/base-rootfs.ext4 /mnt/microvm-root
sudo chroot /mnt/microvm-root
```

Create bootstrap script:

```bash
cat >/usr/local/sbin/project-bootstrap.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

source /etc/project.env

# Create dev user if missing
id "$DEV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV_USER"

install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" /home/$DEV_USER/.ssh
echo "$DEV_SSH_KEY" > /home/$DEV_USER/.ssh/authorized_keys
chmod 600 /home/$DEV_USER/.ssh/authorized_keys
chown -R $DEV_USER:$DEV_USER /home/$DEV_USER/.ssh

# Workspace
install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" /work

# Clone repo if missing
if [ ! -d "/work/$PROJECT/.git" ]; then
  sudo -u "$DEV_USER" git clone "$REPO_URL" "/work/$PROJECT"
fi

cd "/work/$PROJECT"
sudo -u "$DEV_USER" git fetch --all --prune
sudo -u "$DEV_USER" git checkout -f "$GIT_REF"

# Optional: enable agent if present
systemctl enable coding-agent.service 2>/dev/null && systemctl restart coding-agent.service 2>/dev/null || true

# User bootstrap scripts (pass-through)
for f in /etc/bootstrap.d/*.sh; do [ -f "$f" ] && [ -x "$f" ] && "$f" || true; done
EOF
chmod +x /usr/local/sbin/project-bootstrap.sh
```

Create systemd unit:

```bash
cat >/etc/systemd/system/project-bootstrap.service <<'EOF'
[Unit]
Description=Project bootstrap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/project-bootstrap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

Enable it:

```bash
systemctl enable project-bootstrap.service
```

Exit and unmount:

```bash
exit
sudo umount /mnt/microvm-root
```

**Or use:** `./build/run-step05.sh --secure-base` to install this script and unit (and key-only, git) automatically.

---

## 5.4 User bootstrap (pass-through)

To run your own commands at first boot (e.g. install Claude Code, extra packages):

- **Single script:** Set `FIRST_RUN_SCRIPT=/path/on/host/my.sh`. run-step05.sh copies it into the guest as `/etc/bootstrap.d/99-user-bootstrap.sh`.
- **Directory:** Set `BOOTSTRAP_D_DIR=/path/on/host/bootstrap.d/`. run-step05.sh copies all `*.sh` into the guest `/etc/bootstrap.d/`; they run in sort order after core setup.

Scripts run as root. To run as the dev user, use `sudo -u "$DEV_USER" ...` (source `/etc/project.env` in the script if needed).  
Example: `build/bootstrap.d/99-user-example.sh`.

---

## 5.5 Run flow and script (run-step05.sh)

**One-time: secure the base**

```bash
./build/run-step05.sh --secure-base
```

Requires the base image from `run-step04.sh --setup-only`. Applies key-only SSH, lock root, installs git, and adds the first-run script and service. Skips if the base is already secured.

**Launch a project (key-only + injection)**

Set on the host:

- **DEV_SSH_KEY** (required) — public key for `authorized_keys`.
- **REPO_URL**, **GIT_REF** — optional; for clone and checkout.
- **DEV_USER** — optional; default `dev`.
- **FIRST_RUN_SCRIPT** — optional; path to a single script.
- **BOOTSTRAP_D_DIR** — optional; directory of `*.sh` scripts.

Then run:

```bash
./build/run-step05.sh [PROJECT] [SSH_PORT] [--teardown]
```

Example:

```bash
export DEV_SSH_KEY="$(cat ~/.ssh/id_rsa.pub)"
export REPO_URL="https://github.com/you/myproj"
export GIT_REF="main"
./build/run-step05.sh myproj 22240
```

The script creates the project rootfs from the secured base, writes `/etc/project.env`, injects optional bootstrap scripts, patches networking, and starts the VM (same pattern as Step 4). On first boot the guest runs the first-run service (user, keys, repo, then your scripts). SSH with your private key: `ssh -p 22240 dev@HOST_LAN_IP`.

**Summary:** Use `run-step04.sh` for standard (password) bring-up. Use `run-step05.sh` for key-only and metadata-driven bootstrapping; it does not modify any existing .sh files.
