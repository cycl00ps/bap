# STEP 1 — Prepare the AlmaLinux 10 host

This step prepares the AlmaLinux 10 host for Firecracker microVMs. These instructions assume you are logged in as a **non-root user** with `sudo` access.

To run all steps and checks automatically, use the script `build/run-step01.sh`. Run it from an **interactive terminal** so you can enter your sudo password when prompted (or configure passwordless sudo).

## 1.1 Verify hardware virtualization (do this first)

Firecracker requires KVM.

If this fails, nothing else matters.

```bash
lscpu | grep -E 'Virtualization|Vendor ID'
```

You want to see one of (the value may be padded with spaces):

- `Virtualization: VT-x` (Intel)
- `Virtualization: AMD-V` (AMD)

Also check KVM modules:

```bash
lsmod | grep kvm
```

**Expected:**

```text
kvm_intel
kvm
```
or
```text
kvm_amd
kvm
```

If missing, enable virtualization in BIOS/UEFI.

## 1.2 Install base packages (dnf)

These are the minimum required packages for:

- KVM
- networking (TAP, iptables)
- Firecracker operation
- debugging

```bash
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
```

### Why each package matters

| Package     | Why                                                       |
| ----------- | --------------------------------------------------------- |
| qemu-kvm    | Provides /dev/kvm and kernel virtualization support       |
| libvirt     | Not strictly required, but installs useful KVM deps        |
| iproute     | ip, tuntap, routing                                       |
| iptables-nft | NAT + port forwarding                                    |
| firewalld   | Controlled LAN access                                     |
| util-linux  | nsenter, mounts, misc                                     |
| curl        | Firecracker API control                                   |
| socat       | Debugging UNIX sockets                                    |
| jq          | JSON sanity checks                                        |

## 1.3 Enable and start system services

```bash
sudo systemctl enable --now libvirtd
sudo systemctl enable --now firewalld
```

### Verify

```bash
systemctl status libvirtd --no-pager
systemctl status firewalld --no-pager
```

## 1.4 Verify /dev/kvm access

```bash
ls -l /dev/kvm
```

**Expected:** Character device owned by `root` with group `kvm`. The permission bits may be `crw-rw----` (660) or `crw-rw-rw-` (666) depending on the distro.

```text
crw-rw---- 1 root kvm ...
```
(or `crw-rw-rw- 1 root kvm ...` on some systems)

Add yourself to the `kvm` group so your user can access `/dev/kvm` without root. Group membership applies only after a new login session (or after running `newgrp kvm`); until then, `groups` may not show `kvm`.

```bash
sudo usermod -aG kvm $USER
newgrp kvm
```

### Verify

```bash
groups
```

## 1.5 Enable IP forwarding (required for LAN → microVM)

### Immediate (runtime)

```bash
sudo sysctl -w net.ipv4.ip_forward=1
```

### Persistent

```bash
sudo tee /etc/sysctl.d/99-firecracker.conf <<EOF
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

### Verify

```bash
sysctl net.ipv4.ip_forward
```

## 1.6 Configure firewall for LAN-accessible SSH ports

We'll reserve a clean port range for microVM SSH: **20000–29999/tcp**.

Open the range:

```bash
sudo firewall-cmd --permanent --add-port=20000-29999/tcp
sudo firewall-cmd --reload
```

### Verify

```bash
sudo firewall-cmd --list-ports
```

**Expected:**

```text
20000-29999/tcp
```

> 🔒 Later you can restrict this to a dev subnet using rich rules.

## 1.7 Identify your LAN interface (important)

Firecracker NAT rules will need the interface used for the default route. Interface names vary by system (e.g. `eno1`, `eth0`, `enp0s3`, `enp1s0`, `wlan0`).

```bash
ip route show default
```

**Example output:**

```text
default via 10.10.0.1 dev eno1 proto dhcp
```

Set the interface in a variable for Step 3 and Step 4:

```bash
LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
echo "$LAN_IF"
```

Export it so it is available in later steps, or write it down: `export LAN_IF`

## 1.8 Final Step 1 verification checklist

Run these as your normal user (no sudo). All of the following must succeed:

```bash
ls /dev/kvm
sysctl net.ipv4.ip_forward
firewall-cmd --state
ip route show default
```

> **If yes → host is ready.**
