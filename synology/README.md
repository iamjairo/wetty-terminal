# WeTTY Terminal — Synology DSM 7 SPK Package

A self-contained Synology Package (`.spk`) that installs and runs **WeTTY Terminal** on your NAS, giving you a full browser-based SSH terminal to your Synology DiskStation on port **13338**.

---

## Quick start

### 1. Build the SPK (on your desktop/CI machine)

```bash
# x86_64 NAS (most common — DS9xx+, DS7xx+, etc.)
./scripts/build-spk.sh

# aarch64 NAS (e.g. DS223, RT6600ax)
./scripts/build-spk.sh --arch aarch64
```

Prerequisites on the build machine: `bash`, `curl`, `tar`, `pnpm ≥ 9`, `node ≥ 18`.
The script downloads and bundles a Node.js LTS binary automatically — no Node.js needs to be installed on the NAS.

The resulting file is written to `dist/wetty_<version>_<arch>.spk`.

### 2. Install on the NAS

1. Open **Package Center** in DSM.
2. Click **Manual Install** (top-right).
3. Upload the `.spk` file and follow the wizard.
4. Accept the third-party package warning.

### 3. Open WeTTY

After installation, click **Open** in Package Center, or navigate directly to:

```
http://<NAS-IP>:13338/wetty
```

Log in with any DSM user account that has SSH access enabled.

---

## Prerequisites on the NAS

| Requirement | Where to enable |
|---|---|
| SSH service enabled | **Control Panel → Terminal & SNMP → Enable SSH service** |
| SSH port 22 open (default) | Same panel — note the port if you changed it |
| Port 13338 not blocked by firewall | **Control Panel → Security → Firewall** |

---

## Configuration

The active configuration file lives at:

```
/var/packages/wetty/etc/wetty.config
```

It is preserved across upgrades. Key settings:

| Key | Default | Description |
|---|---|---|
| `ssh.host` | `localhost` | SSH target host |
| `ssh.port` | `22` | SSH port |
| `ssh.auth` | `password` | `password` or `publickey,password` |
| `server.port` | `13338` | WeTTY listening port |
| `server.base` | `/wetty/` | URL base path |

After editing, restart the package:

```bash
# DSM SSH shell
synopkg restart wetty
```

---

## Optional: Reverse proxy through DSM HTTPS

To serve WeTTY over HTTPS via DSM's built-in Nginx instead of plain port 13338:

1. Go to **Control Panel → Login Portal → Advanced → Reverse Proxy**.
2. Create a new rule:
   - **Source**: HTTPS, `<your-nas-hostname>`, path `/wetty`
   - **Destination**: HTTP, `127.0.0.1`, port `13338`
3. Under the **Custom Header** tab, add:
   - `Upgrade` → `$http_upgrade`
   - `Connection` → `upgrade`

A ready-made Nginx snippet is also included at:

```
/var/packages/wetty/target/conf/reverse-proxy.conf
```

---

## Build options

```
./scripts/build-spk.sh [OPTIONS]

  --arch <arch>            x86_64 (default) | aarch64
  --node-version <major>   Node.js major to bundle (default: 20)
  -h, --help               Show help
```

---

## Supported NAS architectures

| Architecture | SPK `arch` value | Example models |
|---|---|---|
| Intel/AMD 64-bit | `x86_64` | DS923+, DS720+, DS220+, RS820+ |
| ARM 64-bit | `aarch64` | DS223, DS124, RT6600ax, MR2200ac |

> **Cross-compilation note:** `node-pty` contains native C++ code compiled for the build machine's architecture. Build the SPK on an x86_64 Linux host for x86_64 NAS models. For aarch64, run the build script inside a native or QEMU-emulated aarch64 Docker container.

---

## Uninstall

Open **Package Center**, select **WeTTY Terminal → Action → Uninstall**.

Your customised `/var/packages/wetty/etc/wetty.config` is deleted on full uninstall.

---

## License

MIT — see the project root [`LICENSE`](../LICENSE) file.
