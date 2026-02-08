# STEP 4 — Firecracker microVM: complete runsheet (with logging)

Assume a **non-root user with sudo**: run commands as your normal user and use sudo only where shown.

**Before you start:** Complete Steps 1–3 (host prep, Firecracker and jailer in `/usr/local/bin`, networking scripts and TAP/NAT). If password setup fails (chpasswd "cannot open /etc/passwd" or "failure while writing to /etc/shadow"), SELinux may be blocking it; run `sudo setenforce 0` temporarily for the setup/run, or put SELinux in permissive mode.

**Assumptions:** AlmaLinux 10 host, project name `myproj`, SSH port `22240`, LAN interface = default-route interface (set `LAN_IF` as in Step 1/3 or pass `auto` to the scripts). You have `microvm-net-up.sh` (and optionally `microvm-net-down.sh`) on the host, e.g. in the build directory or installed in `/usr/local/sbin`.

---

## 4.1 Get a Firecracker-compatible kernel

```bash
sudo mkdir -p /var/lib/microvms/kernels
cd /var/lib/microvms/kernels
sudo wget https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/vmlinux-5.10.bin
sudo chmod 644 vmlinux-5.10.bin
file vmlinux-5.10.bin
# Expected: ELF 64-bit LSB executable, x86-64, statically linked
```

---

## 4.2 Create base rootfs (once)

### 4.2.1 Create disk image

```bash
sudo mkdir -p /var/lib/microvms/base
cd /var/lib/microvms/base
sudo dd if=/dev/zero of=base-rootfs.ext4 bs=1M count=2048
sudo mkfs.ext4 base-rootfs.ext4
```

### 4.2.2 Mount and install packages

From `/var/lib/microvms/base` (or use the full path in the mount command below):

```bash
sudo mkdir -p /mnt/microvm-root
sudo mount -o loop /var/lib/microvms/base/base-rootfs.ext4 /mnt/microvm-root

sudo dnf install --installroot=/mnt/microvm-root \
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
  NetworkManager
```

### 4.2.3 Mount dev/proc/sys and chroot to configure

```bash
sudo mount --bind /dev /mnt/microvm-root/dev
sudo mount -t proc proc /mnt/microvm-root/proc
sudo mount -t sysfs sys /mnt/microvm-root/sys
sudo chroot /mnt/microvm-root
```

**Inside chroot:**

- Set root password: `passwd`
- Enable SSH: `systemctl enable sshd`
- Create user:  
  `useradd -m -s /bin/bash dev`  
  `passwd dev`  
  `usermod -aG wheel dev`
- Sudo for wheel:  
  `echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/wheel`  
  `chmod 440 /etc/sudoers.d/wheel`
- NetworkManager static connection (placeholder IPs; you'll patch per project):

```bash
mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/eth0.nmconnection << 'EOF'
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
EOF
chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection
```

- Enable NetworkManager: `systemctl enable NetworkManager`
- Hostname: `echo microvm > /etc/hostname`
- Exit chroot: `exit`

### 4.2.4 Unmount (submounts first, then root)

```bash
sudo umount /mnt/microvm-root/dev /mnt/microvm-root/proc /mnt/microvm-root/sys
sudo umount /mnt/microvm-root
```

---

## 4.3 Fix microvm-net-up.sh for /30 (once)

Use valid /30 host addresses (not network or broadcast). In `microvm-net-up.sh` (in the build directory, your home directory, or, if already installed, in `/usr/local/sbin`), set:

```bash
BLOCK=$(( (B % 252) / 4 * 4 ))
HOST_IP="172.31.${SUBNET_A}.$((BLOCK + 1))"
GUEST_IP="172.31.${SUBNET_A}.$((BLOCK + 2))"
CIDR="30"
```

(Keep existing `HASH`, `A`, `B`, `SUBNET_A`; only change last-octet logic.)

---

## 4.4 Per-project setup

### 4.4.1 Bring up networking and get IPs

Ensure `LAN_IF` is set (as in Step 1 or 3), or omit the third argument to auto-detect:

```bash
sudo /usr/local/sbin/microvm-net-up.sh myproj 22240 $LAN_IF
```

(If you did not install to `/usr/local/sbin`, use `sudo ./microvm-net-up.sh` or `sudo ~/microvm-net-up.sh` with the same arguments.)

Set variables from the script output (use the printed values):

```bash
GUEST_IP=172.31.xxx.xxx
HOST_IP=172.31.xxx.xxx
PROJECT=myproj
```

### 4.4.2 Copy base rootfs and patch IPs

If `/mnt/microvm-root` is already in use, unmount it first: `sudo umount /mnt/microvm-root` (and any submounts if present).

```bash
sudo mkdir -p /var/lib/microvms/${PROJECT}
sudo cp --reflink=auto /var/lib/microvms/base/base-rootfs.ext4 /var/lib/microvms/${PROJECT}/rootfs.ext4

sudo mount -o loop /var/lib/microvms/${PROJECT}/rootfs.ext4 /mnt/microvm-root

sudo tee /mnt/microvm-root/etc/NetworkManager/system-connections/eth0.nmconnection << EOF
[connection]
id=eth0
type=ethernet
interface-name=eth0

[ipv4]
method=manual
addresses=${GUEST_IP}/30
gateway=${HOST_IP}
dns=1.1.1.1;

[ipv6]
method=disabled
EOF

sudo chmod 600 /mnt/microvm-root/etc/NetworkManager/system-connections/eth0.nmconnection
sudo umount /mnt/microvm-root
```

---

## 4.5 Start Firecracker (with logging)

Order: 4.5.1 (clean + start jailer) → 4.5.2 (wait for socket) → 4.5.4 (bind-mount kernel and rootfs) → 4.5.5 (configure and start VM). Optionally 4.5.3 (logger via API) after 4.5.2.

Ensure `PROJECT` (and `GUEST_IP`/`HOST_IP`) are set from 4.4.1.

### 4.5.1 Clean leftover chroot and start jailer with logging

Unmount any previous bind mounts and remove the project's jail directory so the jailer can create a fresh chroot. Start the jailer with Firecracker writing logs to a file and to a host-visible path:

```bash
# Unmount bind mounts from any previous run
sudo umount /srv/jailer/firecracker/${PROJECT}/root/var/lib/microvms/kernels 2>/dev/null || true
sudo umount /srv/jailer/firecracker/${PROJECT}/root/var/lib/microvms/${PROJECT} 2>/dev/null || true

# Remove leftover chroot (avoids "File exists" for /dev/net/tun)
sudo rm -rf /srv/jailer/firecracker/${PROJECT}

# Optional: create log file on host so you can tail it
sudo mkdir -p /var/log/firecracker
sudo touch /var/log/firecracker/${PROJECT}.log

# Start jailer with Firecracker logging to a file inside the chroot (viewable on host)
# and redirect jailer's own stdout/stderr to a file for full visibility
sudo jailer \
  --id ${PROJECT} \
  --exec-file /usr/local/bin/firecracker \
  --uid 0 --gid 0 \
  --chroot-base-dir /srv/jailer \
  -- \
  --api-sock /firecracker.socket \
  --log-path /firecracker.log \
  --level Debug \
  &> /var/log/firecracker/${PROJECT}.log &
```

**View Firecracker logs (choose one or both):**

- Firecracker's own log (inside chroot):
  ```bash
  sudo tail -f /srv/jailer/firecracker/${PROJECT}/root/firecracker.log
  ```
- Everything from the jailer process (stdout/stderr):
  ```bash
  sudo tail -f /var/log/firecracker/${PROJECT}.log
  ```

### 4.5.2 Wait for socket

```bash
sudo bash -c 'export FC_SOCK="/srv/jailer/firecracker/'"${PROJECT}"'/root/firecracker.socket"; until [ -S "$FC_SOCK" ]; do sleep 0.1; done; echo "Socket ready"'
```

### 4.5.3 (Optional) Configure logger via API

If you prefer to set log level/path via API instead of command line, do this once the socket is ready and before other API calls:

```bash
FC_SOCK="/srv/jailer/firecracker/${PROJECT}/root/firecracker.socket"

sudo curl --unix-socket "$FC_SOCK" -i -H "Content-Type: application/json" \
  -X PUT http://localhost/logger \
  -d '{
    "log_path": "/firecracker.log",
    "level": "Debug",
    "show_level": true,
    "show_log_origin": true
  }'
```

Then tail the same file on the host:  
`sudo tail -f /srv/jailer/firecracker/${PROJECT}/root/firecracker.log`

### 4.5.4 Bind-mount kernel and rootfs into chroot

```bash
CHROOT_ROOT="/srv/jailer/firecracker/${PROJECT}/root"
sudo mkdir -p "${CHROOT_ROOT}/var/lib/microvms/kernels"
sudo mount --bind /var/lib/microvms/kernels "${CHROOT_ROOT}/var/lib/microvms/kernels"
sudo mkdir -p "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
sudo mount --bind /var/lib/microvms/${PROJECT} "${CHROOT_ROOT}/var/lib/microvms/${PROJECT}"
```

### 4.5.5 Configure VM via API

Use the full socket path (or keep `FC_SOCK` set from above):

```bash
FC_SOCK="/srv/jailer/firecracker/${PROJECT}/root/firecracker.socket"
```

**Machine config:**

```bash
sudo curl --unix-socket "$FC_SOCK" -i -H "Content-Type: application/json" \
  -X PUT http://localhost/machine-config \
  -d '{ "vcpu_count": 2, "mem_size_mib": 2048, "smt": false }'
```

**Boot source:**

```bash
sudo curl --unix-socket "$FC_SOCK" -i -H "Content-Type: application/json" \
  -X PUT http://localhost/boot-source \
  -d '{"kernel_image_path": "/var/lib/microvms/kernels/vmlinux-5.10.bin", "boot_args": "console=ttyS0 reboot=k panic=1 pci=off clocksource=tsc tsc=reliable"}'
```

**Rootfs:**

```bash
sudo curl --unix-socket "$FC_SOCK" -i -H "Content-Type: application/json" \
  -X PUT http://localhost/drives/rootfs \
  -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"/var/lib/microvms/${PROJECT}/rootfs.ext4\", \"is_root_device\": true, \"is_read_only\": false}"
```

**Network:**

```bash
sudo curl --unix-socket "$FC_SOCK" -i -H "Content-Type: application/json" \
  -X PUT http://localhost/network-interfaces/eth0 \
  -d "{\"iface_id\": \"eth0\", \"host_dev_name\": \"tap-${PROJECT}\"}"
```

**Start VM:**

```bash
sudo curl --unix-socket "$FC_SOCK" --max-time 5 -i -H "Content-Type: application/json" \
  -X PUT http://localhost/actions \
  -d '{ "action_type": "InstanceStart" }'
```

---

## 4.6 Test

From another machine on the LAN (use your host's LAN IP). On the host, your LAN IP is shown by: `ip -4 -o addr show $LAN_IF | awk '{print $4}' | cut -d/ -f1` (or use the same IP you use to SSH to the host).

```bash
ssh -p 22240 dev@<HOST_LAN_IP>
```

Inside the VM:

```bash
ip addr show eth0
ip route
ping -c 2 1.1.1.1
```

---

## 4.7 Stop VM and cleanup

**Graceful:**

```bash
sudo curl --unix-socket /srv/jailer/firecracker/${PROJECT}/root/firecracker.socket -i \
  -H "Content-Type: application/json" -X PUT http://localhost/actions \
  -d '{ "action_type": "SendCtrlAltDel" }'
```

**Force:**

```bash
sudo pkill -f "jailer.*${PROJECT}"
```

**Unmount bind mounts:**

```bash
sudo umount /srv/jailer/firecracker/${PROJECT}/root/var/lib/microvms/kernels
sudo umount /srv/jailer/firecracker/${PROJECT}/root/var/lib/microvms/${PROJECT}
```

**Tear down networking (if you have a down script):**

```bash
sudo /usr/local/sbin/microvm-net-down.sh ${PROJECT} 22240 $LAN_IF
```

(If you did not install to `/usr/local/sbin`, use `sudo ./microvm-net-down.sh` or `sudo ~/microvm-net-down.sh` with the same arguments.)

---

## 4.8 See how many microVMs are running

Count and list running microVMs by inspecting **firecracker** processes (the jailer may exit after starting firecracker, so counting jailer is unreliable):

```bash
# Count
ps -eo args | grep '[f]irecracker' | grep -- '--id' | wc -l

# List project ids (one per line)
ps -eo args | grep '[f]irecracker' | grep -- '--id' | sed -n 's/.*--id[= ]\([^ ]*\).*/\1/p'
```

Use `[f]irecracker` in grep so the grep process itself is not matched. Do not rely on counting jailer processes or on `pgrep -f` (it can match the invoking shell).

---

## 4.9 Step 4 checklist

- VM boots and you see login prompt (e.g. via serial or by SSH).
- From a machine on the LAN, SSH to the microVM works: `ssh -p 22240 dev@<HOST_LAN_IP>`.
- Inside the VM, `ping -c 2 1.1.1.1` works.
- After cleanup (4.7), bind mounts and the TAP device for the project are gone; networking teardown succeeded if you use the down script.

---

## Logging reference

Paths below use project id `myproj`; substitute your project name or use `$PROJECT` if you set that variable.

| What | Where |
|------|--------|
| Firecracker's log (from `--log-path`) | `sudo tail -f /srv/jailer/firecracker/${PROJECT}/root/firecracker.log` |
| Jailer + Firecracker stdout/stderr | `sudo tail -f /var/log/firecracker/${PROJECT}.log` |
| Log level | `--level Debug` (or `Info`, `Warn`, `Error`) on jailer command line, or set via `PUT /logger` before other API calls |

If you see errors in the API (e.g. 400 for boot or drives), check these logs first; they usually show the underlying cause (e.g. file not found, permission, or invalid config).

**VM fails to boot with `MissingAddressRange` (0x70, 0x71, 0x87):** The guest kernel is accessing I/O ports that Firecracker does not emulate (RTC/CMOS at 0x70/0x71, or legacy port 0x87). The run script uses `clocksource=tsc tsc=reliable` in `boot_args` to reduce RTC probing. If the pre-built kernel from the script’s URL still triggers these errors, use a Firecracker-built kernel: clone the [Firecracker repo](https://github.com/firecracker-microvm/firecracker), run `./tools/devtool build_ci_artifacts kernels 5.10`, then copy the built `vmlinux` to `/var/lib/microvms/kernels/vmlinux-5.10.bin` (or set the script’s fallback by placing it in the build directory next to run-step04.sh or in `$HOME/vmlinux-5.10.bin`).
