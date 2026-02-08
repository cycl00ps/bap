# Step 2 — Install Firecracker properly

Assume a **non-root user with sudo**: run commands as your normal user and use `sudo` only where shown.

We will:

- install Firecracker + jailer binaries
- lay out directories cleanly
- verify the binary runs

## 2.1 Create directory layout (do this first)

```bash
sudo mkdir -p \
  /var/lib/microvms/{kernels,base} \
  /srv/jailer \
  /usr/local/bin
```

### Permissions

```bash
sudo chmod 755 /var/lib/microvms /srv/jailer
```

## 2.2 Download Firecracker binaries

Firecracker ships matching versions of **firecracker** and **jailer**; they must be the same version. To see the latest release and release notes, go to: **<https://github.com/firecracker-microvm/firecracker/releases>**. You can pin a specific version by setting `FC_VERSION` (see Option B).

**Option A — Automatic (latest for your architecture)**

Uses the latest release and your machine’s architecture (`uname -m`). If `jq` is available, you can use `FC_VERSION=$(curl -sL ... | jq -r '.tag_name')` instead of the `grep`/`sed` below.

```bash
FC_VERSION=$(curl -sL https://api.github.com/repos/firecracker-microvm/firecracker/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
ARCH=$(uname -m)

wget -qO firecracker.tgz \
  https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz
```

**Option B — Pin a specific version**

Set `FC_VERSION` and `ARCH` manually (e.g. from the [releases](https://github.com/firecracker-microvm/firecracker/releases) page), then download:

```bash
FC_VERSION="v1.14.1"
ARCH="x86_64"

wget -qO firecracker.tgz \
  https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz
```

**Extract** (after either option):

```bash
tar -xzf firecracker.tgz
```

**Install binaries:**

```bash
sudo install -m 755 release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH} /usr/local/bin/firecracker
sudo install -m 755 release-${FC_VERSION}-${ARCH}/jailer-${FC_VERSION}-${ARCH} /usr/local/bin/jailer
```

**Cleanup:**

```bash
rm -rf firecracker.tgz release-${FC_VERSION}-${ARCH}
```

## 2.3 Verify binaries

```bash
firecracker --version
jailer --version
```

**Expected (example):**

```
Firecracker v1.7.0
```

## 2.4 Quick sanity check: Firecracker starts

Firecracker listens on a UNIX socket. This confirms the binary works and kernel + libc are OK.

**Terminal 1 — start Firecracker:**

```bash
sudo firecracker --api-sock /tmp/fc-test.sock
```

**Terminal 2 — probe the API:**

```bash
sudo curl --unix-socket /tmp/fc-test.sock http://localhost/
```

**Expected:**

```json
{"error":"Invalid request method"}
```

Stop the Firecracker process in terminal 1 with **Ctrl+C**. If you saw that response, Firecracker is healthy.

## 2.5 Why we will use jailer (important context)

Firecracker expects to be run with **jailer** in production-like setups:

- chroot per microVM
- seccomp filters
- cgroup isolation
- filesystem containment

This is not optional hardening — AWS designed it this way. We will always launch Firecracker via jailer going forward.

## 2.6 Verification checklist

Run:

```bash
which firecracker
which jailer
firecracker --version
ls /srv/jailer
```

If all succeed, you’re ready for networking + VM boot.
