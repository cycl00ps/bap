# STEP 3 — Firecracker host networking (LAN-reachable)

This step sets up host networking for Firecracker microVMs. Assume a **non-root user with sudo**: run commands as your normal user and use `sudo` only where shown.

**Before you start:** Complete Step 1 and Step 2 (IP forwarding, firewall, LAN interface, Firecracker binaries).

We’ll build it using:

- TAP devices
- iptables NAT
- LAN-reachable port forwarding
- clean teardown

So that:

- each project gets its own TAP
- each project gets a tiny /30 subnet
- each project gets one SSH port on the host
- devs connect from the LAN to `<host-ip>:22xxx`

No Kubernetes. No bridges. No magic.

## What we’re building (mental model)

```text
[ Dev Laptop ]
      |
      | ssh :22240
      v
[ Host LAN_IF ]  <-- DNAT :22240 → 172.31.12.1:22
      |
      | FORWARD
      v
[ tap-myproj ] 172.31.12.0/30
      |
      v
[ microVM eth0 ] 172.31.12.1
```

Outbound traffic: microVM → tap → host → LAN if → internet

## 3.1 Identify host interfaces (double-check)

We already did this in Step 1, but confirm:

```bash
ip route show default
```

**Example:**

```text
default via 10.0.0.1 dev eno1 proto dhcp
```

Your interface name may differ (e.g. `eth0`, `enp0s3`). Derive the LAN interface from the default route and set it once:

```bash
LAN_IF=$(ip route show default | awk '/^default/ {print $5}')
echo "$LAN_IF"
```

## 3.2 Decide IP space for microVMs

We’ll use a private, non-routed range: **172.31.0.0/16**.

Each microVM gets a /30:

- 4 addresses total
- 2 usable
- perfect for host ↔ VM

**Example for one project:**

| Role   | Address        |
|--------|----------------|
| Host (tap) | 172.31.12.0 |
| Guest (VM) | 172.31.12.1 |
| Netmask   | /30        |

## 3.3 Use the networking scripts (core of Step 3)

Use the scripts from the build directory (same directory as `run-step03.sh`) or your home directory:

- `build/microvm-net-up.sh`, `build/microvm-net-down.sh` (or `~/microvm-net-up.sh`, `~/microvm-net-down.sh`)

They use a BLOCK-based /30 so only valid host addresses (.1 and .2) are used. The teardown script uses the same calculation so it removes the correct iptables rules and TAP.

**Option A — Install to /usr/local/sbin (recommended)**

Copy the scripts from the build directory (or home) so they are on PATH and runnable with `sudo microvm-net-up.sh ...`:

```bash
sudo cp build/microvm-net-up.sh build/microvm-net-down.sh /usr/local/sbin/
sudo chmod +x /usr/local/sbin/microvm-net-*.sh
```

Or from the build directory: `sudo cp ./microvm-net-up.sh ./microvm-net-down.sh /usr/local/sbin/`

**Option B — Run from build directory or home**

Use the full path when calling them:

```bash
sudo ./microvm-net-up.sh <project> <ssh-port> <lan-if>
sudo ./microvm-net-down.sh <project> <ssh-port> <lan-if>
```

(or `sudo ~/microvm-net-up.sh ...` if running from home)

Usage (same for both options):

```text
microvm-net-up.sh   <project> <ssh-port> [<lan-if>]
microvm-net-down.sh <project> <ssh-port> [<lan-if>]
```

You can pass the LAN interface name (e.g. `$LAN_IF` after setting it as in 3.1), or omit it / pass `auto` to use the default-route interface automatically.

Example: `microvm-net-up.sh myproj 22240 $LAN_IF` or `microvm-net-up.sh myproj 22240` (auto-detect)

## 3.4 Teardown script (important!)

The same script `microvm-net-down.sh` (in the build directory, `~`, or in `/usr/local/sbin`) performs cleanup. Always tear down when you are done so iptables and TAP devices are removed:

```bash
sudo microvm-net-down.sh <project> <ssh-port> <lan-if>
```

(Use `sudo ./microvm-net-down.sh ...` or `sudo ~/microvm-net-down.sh ...` if you did not install to `/usr/local/sbin`.)

## 3.5 Test networking without Firecracker (important sanity test)

Confirm the host side works before involving VMs.

**Create a TAP manually**

If you installed to `/usr/local/sbin`:

```bash
sudo microvm-net-up.sh testproj 22240 $LAN_IF
```

If you are running from the build directory or home:

```bash
sudo ./microvm-net-up.sh testproj 22240 $LAN_IF
# or: sudo ~/microvm-net-up.sh testproj 22240 $LAN_IF
```

**Verify:**

```bash
ip addr show tap-testproj
iptables -t nat -L -n
iptables -L FORWARD -n
```

**Expected:**

- `tap-testproj` exists
- IP in 172.31.x.y/30
- NAT + FORWARD rules present

**Tear it down:**

```bash
sudo microvm-net-down.sh testproj 22240 $LAN_IF
```

(or `sudo ./microvm-net-down.sh testproj 22240 $LAN_IF` or `sudo ~/microvm-net-down.sh ...` if running from build dir or home)

**Confirm:**

```bash
ip addr show tap-testproj   # should not exist
```

## 3.6 Why this design works (important understanding)

- TAP gives Firecracker a raw L2 interface
- /30 subnet avoids ARP chaos and IP collisions
- iptables DNAT exposes only what you want
- No bridge = fewer moving parts
- LAN clients hit host → host routes to VM

This is the exact pattern Firecracker documents for host networking: [Firecracker networking](https://github.com/firecracker-microvm/firecracker) and what many production users run with.

## 3.7 Step 3 checklist (must pass)

Run:

```bash
sysctl net.ipv4.ip_forward
firewall-cmd --list-ports | grep 20000
ls /usr/local/sbin/microvm-net-up.sh
ls /usr/local/sbin/microvm-net-down.sh
```

(If you use Option B and run scripts from the build directory or home, ensure they exist: `ls ./microvm-net-up.sh ./microvm-net-down.sh` or `ls ~/microvm-net-up.sh ~/microvm-net-down.sh`.)

Verify firewall allows your SSH port range (from Step 1); the grep above checks for 20000–29999.

Then:

```bash
sudo microvm-net-up.sh sanity 22250 $LAN_IF
sudo microvm-net-down.sh sanity 22250 $LAN_IF
```

(Use `sudo ./microvm-net-up.sh` and `sudo ./microvm-net-down.sh` or `sudo ~/microvm-net-*.sh` if you did not install to `/usr/local/sbin`. You can also omit the third argument or pass `auto` to use the default-route interface.)

If all good → networking is done.

## What’s next (Step 4 preview)

Next step is booting a real microVM:

- kernel image
- rootfs
- Firecracker API config
- attaching this TAP
- logging into the VM

That’s the point where:

- SSH works
- VSCode/Cursor attaches
- Pattern 3 becomes “real”
