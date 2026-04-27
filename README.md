# talos-rpi-cm5-builder

[![Build and Publish](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml)
[![Build Kernel](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/build-kernel.yml)
[![Build Overlay](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/build-overlay.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/build-overlay.yml)

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM4, CM5, and Pi 5** on CM4IO/CM5IO-compatible carrier boards (e.g. DeskPi Super6C).

Builds a single `rpi_generic` image that works across CM4, CM5, and Pi 5 boards.

The build pipeline is fully self-contained — the kernel (`ghcr.io/wheetazlab/rpi-talos`) is built from source via `build-kernel.yml`, with three macb ethernet patches applied on top of the Pi Foundation vendor kernel. The disk image is assembled by `publish.yml` using that kernel image plus a custom `sbc-raspberrypi` overlay (full BCM2712/RP1 U-Boot with NVMe/PCIe support, unified `rpi_generic` installer), `iscsi-tools`, and `util-linux-tools`.

## Background

Talos ≤ v1.12.2 could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

NVMe boot support is provided by a patched U-Boot baked into the custom `sbc-raspberrypi` overlay, sourced from [sidero-community/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88). PR #88 replaces the old NVMe-only patch with 14 comprehensive BCM2712/RP1 patches and unifies CM4/CM5 into a single `rpi_generic` installer overlay.

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

### macb kernel patches

Three patches are applied to the Pi Foundation vendor kernel (`patches/linux/`) to fix silent TX stall issues on PCIe-attached macb ethernet (BCM2712/RP1):

| Patch | Fix |
|-------|-----|
| `0001` | Flush PCIe posted write after TSTART doorbell |
| `0002` | Re-check ISR after IER re-enable in `macb_tx_poll` |
| `0003` | TX stall watchdog — defence-in-depth per-queue `delayed_work` |

These patches address [sbc-raspberrypi#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82) / [cilium#43198](https://github.com/cilium/cilium/issues/43198).

---

## ⚠️ EEPROM Requirement

**Before flashing, ensure your CM5 is running the latest bootloader EEPROM.** An outdated EEPROM can cause boot failures, NVMe detection issues, or hangs at the U-Boot logo that look like image problems but aren't.

### Check your current EEPROM version

Boot into Raspberry Pi OS and run:

```bash
sudo rpi-eeprom-update
```

### Update to latest

```bash
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a
sudo reboot
```

After reboot, verify with `sudo rpi-eeprom-update` — it should report no update needed.

### If the CM5 has never booted an OS

Flash Raspberry Pi OS to an SD card, boot from it once (this automatically updates the EEPROM), then proceed to flash Talos.

> **Why this matters:** NVMe boot and PCIe support depend on EEPROM firmware features added in late 2024. Boards shipped with older firmware may fail to enumerate NVMe devices in U-Boot regardless of the kernel/DTB configuration.

---

## Versions

| Component             | Version / Image |
|-----------------------|----------------|
| Talos Linux           | `v1.12.7`      |
| Linux kernel          | `6.18.24` (Pi Foundation vendor kernel, `rpi-6.18.y` branch) |
| SBC overlay           | `ghcr.io/wheetazlab/sbc-raspberrypi:pr88` (PR #88 — BCM2712/RP1 U-Boot + NVMe) |
| iscsi-tools extension | `v0.2.0`       |
| util-linux-tools      | `2.41.2`       |
| Installer base        | `ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-6.18.24-macb` (built by `build-kernel.yml`) |

All versions are configurable — see [Customization](#customization).

---

## CI/CD

Images are built automatically on GitHub Actions using a native **Ubuntu arm64** runner — no cross-compilation needed.

All workflow files use `github.repository_owner` for all GHCR paths — they are fully portable. Forks automatically publish to the forker's own GHCR namespace.

### Build Patched Kernel (`build-kernel.yml`)

Builds the custom installer-base OCI image that `publish.yml` consumes. Run this first whenever you bump Talos or want to update the kernel/macb patches.

**Pipeline:**
1. Clones `siderolabs/pkgs` at `PKG_VERSION`, applies the Pi Foundation vendor kernel patch (`patches/siderolabs/pkgs/`)
2. Copies `patches/linux/*.patch` (3 macb patches) into the pkgs kernel patch directory
3. Builds and pushes `ghcr.io/<owner>/kernel:<pkgs-tag>`
4. Clones `siderolabs/talos`, applies `patches/siderolabs/talos/` patches
5. Builds and pushes `installer-base` with the custom kernel
6. `crane copy`s to `ghcr.io/<owner>/rpi-talos:<installer_tag>` (e.g. `v1.12.7-k-6.18.24-macb`)

**Trigger:** Actions → Build Patched Kernel Installer Base → Run workflow

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `talos_version` | `v1.12.7` | Talos branch to build |
| `pkg_version` | `v1.12.0` | `siderolabs/pkgs` branch/tag |
| `installer_tag` | `v1.12.7-k-6.18.24-macb` | Output image tag |

Also triggers on push of a `v*-kernel` tag (e.g. `v1.12.7-kernel`).

**After running:** no manual step needed — `CUSTOM_INSTALLER_BASE` in the Makefile already points to the output tag. The summary tab shows the exact image ref to confirm.

**Update flow for a new Talos version:**
1. Update `TALOS_VERSION`, `CUSTOM_INSTALLER_BASE` in `Makefile` and `scripts/build.sh`
2. Trigger `build-kernel.yml` with the new version inputs
3. Tag + push → `publish.yml` runs automatically

### Build and Publish (`publish.yml`)

The standard image build pipeline. Assembles the disk image and upgrade installer using the pre-built kernel installer base.

**Triggers:**
- Push a version tag (e.g. `git tag v1.12.7 && git push --tags`) → full build + publish
- Manual run via **Actions → Build and Publish → Run workflow**

**Workflow dispatch inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `talos_version` | _(from Makefile)_ | Override Talos version |
| `extra_kernel_args` | _(empty)_ | Space-separated `key=value` kernel args (e.g. `cma=256M hugepages=64`) |
| `extra_extensions` | _(empty)_ | Extra extension image refs on top of the two defaults |

**Pipeline jobs:**
1. **`resolve-version`** — resolves Talos version, reads `CUSTOM_INSTALLER_BASE` and `CUSTOM_OVERLAY_IMAGE` from Makefile; forwards `extra_kernel_args` and `extra_extensions`
2. **`build`** — resolves extension images to digests via `crane digest` for reproducible builds, then:
   - Builds disk image (`make build`)
   - Builds installer OCI (`make installer`)
   - Pushes installer to GHCR tagged `:vX.Y.Z-rpi-kernel`
   - Uploads `metal-arm64.raw.xz` as artifact
3. **`release`** — downloads artifact and creates the GitHub release

### Build Custom Overlay (`build-overlay.yml`)

Manually-triggered workflow that builds and pushes `ghcr.io/<owner>/sbc-raspberrypi:<tag>` from the sidero-community PR #88 fork. Run this when PR #88 gets new commits or is merged upstream.

**Trigger:** Actions → Build Custom SBC Overlay → Run workflow

**Inputs:**
- `pr88_sha` — commit SHA in `sidero-community/sbc-raspberrypi` (default: PR #88 head)
- `overlay_tag` — image tag to publish (default: `pr88`)

After running, update `CUSTOM_OVERLAY_IMAGE` in the Makefile to the new tag.

> **⚠️ Required GitHub permissions (org repos only)**
>
> If this repo is under a **GitHub Organization**, the default `GITHUB_TOKEN` cannot push to GHCR unless the org explicitly allows it. Without this, every push step will fail with `permission_denied: write_package`.
>
> Fix via API or UI:
> - **UI:** Organization → Settings → Actions → General → Workflow permissions → **Read and write permissions**
> - **CLI:**
> ```bash
> gh api --method PUT /orgs/<YOUR_ORG>/actions/permissions/workflow \
>   --field default_workflow_permissions=write \
>   --field can_approve_pull_request_reviews=true
> ```
> This only needs to be set once per organization.

---

## Prerequisites (local builds only)

- **Podman** or **Docker** (with privileged container support)
- **macOS** or **Linux** host (arm64 recommended for U-Boot build)
- `make`
- `gh` CLI for publishing: `brew install gh && gh auth login`

---

## Quick Start

### Download a release

Download from the [Releases page](https://github.com/wheetazlab/talos-rpi-cm5-builder/releases):

| File | For |
|------|-----|
| `metal-arm64.raw.xz` | CM4, CM5, Pi 5 (all variants) |

### Flash to SD card / eMMC

```bash
# macOS
xzcat metal-arm64.raw.xz | sudo dd of=/dev/rdiskN bs=4m

# Linux
xzcat metal-arm64.raw.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

Or with make (after building locally):
```bash
make flash-sd DISK=/dev/rdisk4
```

### eMMC via rpiboot

1. Set the CM5 into USB boot mode (check your carrier board manual for the jumper/button)
2. Connect via USB-C and run `sudo rpiboot`
3. Flash to the exposed eMMC disk


---

## Local Build

```bash
# Full pipeline (build image + installer + push + release)
make publish

# Individual steps
make build        # Talos disk image → _out/metal-arm64.raw.xz
make installer    # Installer OCI   → _out/installer-arm64.tar
make release      # GitHub release with .raw.xz artifact
```

---

## Customization

```bash
# Different Talos version
make build TALOS_VERSION=v1.12.7

# Override overlay image
make build CUSTOM_OVERLAY_IMAGE=ghcr.io/wheetazlab/sbc-raspberrypi:pr88

# Extra kernel args
make build EXTRA_KERNEL_ARGS='--extra-kernel-arg=cma=256M --extra-kernel-arg=hugepages=64'
```

### Custom extensions

Override the full extension set (replaces defaults):

```bash
make build EXTENSIONS="ghcr.io/siderolabs/iscsi-tools:v0.2.0 ghcr.io/siderolabs/util-linux-tools:2.41.2 ghcr.io/siderolabs/gvisor:20260202.0"
```

Or append a single extra extension on top of defaults via `build.sh`:

```bash
./scripts/build.sh --extension ghcr.io/siderolabs/gvisor:20260202.0
```

Multiple `--extension` flags are supported:

```bash
./scripts/build.sh \
  --extension ghcr.io/siderolabs/gvisor:20260202.0 \
  --extension ghcr.io/siderolabs/kata-containers:3.7.0
```

Browse available extensions: https://github.com/siderolabs/extensions

### Extra kernel args via build.sh

```bash
./scripts/build.sh --kernel-arg cma=256M --kernel-arg hugepages=64
```

### Via workflow dispatch (CI)

`publish.yml` exposes `extra_kernel_args` and `extra_extensions` as workflow inputs. Extension images are resolved to digests (`image@sha256:...`) before the build for reproducibility.

---

## Build Targets

```
make build          Build the raw disk image
make installer      Build the Talos installer image (for talosctl upgrade)
make publish        Full pipeline: build → installer → push → release
make flash-sd       Flash image to disk (requires DISK=/dev/rdiskN)
make pull-images    Pre-pull all required container images
make clean          Remove _out/ directory
make help           Show all targets and version variables
```

---

### What's in the image?

- Talos Linux kernel + initramfs (arm64) — from `ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-6.18.24-macb` (Pi Foundation vendor kernel `rpi-6.18.y`, built by `build-kernel.yml` with 3 macb patches applied)
- **Patched U-Boot** (BCM2712/RP1) from `ghcr.io/wheetazlab/sbc-raspberrypi:pr88` (PR #88 patch set — NVMe/PCIe, EEE LPI, MACB driver)
- DTBs from custom `sbc-raspberrypi` overlay (`rpi_generic` installer):
  - `bcm2712-rpi-cm5-cm4io.dtb` ← CM4IO-compatible carriers (e.g. DeskPi Super6C)
  - `bcm2712-rpi-cm5-cm5io.dtb`
  - `bcm2712-rpi-cm5l-cm4io.dtb`
  - `bcm2712-rpi-cm5l-cm5io.dtb`
  - `bcm2712-rpi-5-b.dtb`
  - `bcm2712d0-rpi-5-b.dtb`
- System extension: `iscsi-tools v0.2.0`
- System extension: `util-linux-tools 2.41.2`
- Kernel arg: _(none — single image supports all CM4/CM5/Pi5 variants)

---

## After Booting

Talos enters **maintenance mode** waiting for a machine config:

```bash
# Generate config
talosctl gen config my-cluster https://<CONTROLPLANE_IP>:6443 \
  --additional-sans <CONTROLPLANE_IP>

# Apply to node
talosctl apply-config --insecure --nodes <NODE_IP> --file controlplane.yaml \
  --talosconfig talosconfig

# Bootstrap etcd (first control-plane node only)
talosctl bootstrap --nodes <CONTROLPLANE_IP> --talosconfig talosconfig

# Get kubeconfig
talosctl kubeconfig --nodes <CONTROLPLANE_IP> --talosconfig talosconfig
```

To upgrade an existing node:

```bash
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.7-rpi-kernel
```

---

## References

**Talos / SBC**
- [Talos Linux docs — SBC support](https://www.talos.dev/v1.12/talos-guides/install/single-board-computers/)
- [sbc-raspberrypi releases](https://github.com/siderolabs/sbc-raspberrypi/releases)
- [BCM2712/RP1 U-Boot + NVMe (sbc-raspberrypi PR #88)](https://github.com/siderolabs/sbc-raspberrypi/pull/88)
- [CM5 boot issue fix (sbc-raspberrypi#79)](https://github.com/siderolabs/sbc-raspberrypi/pull/79)
- [Original boot issue (talos#12748)](https://github.com/siderolabs/talos/issues/12748)
- [Talos system extensions](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [DeskPi Super6C](https://deskpi.com/products/deskpi-super6c-raspberry-pi-cm4-6-boards-cluster-mini-itx-board) — example CM4IO-compatible carrier board

**Issue 91 / vendor-kernel / macb patches**
- [macb TX stall tracking issue (sbc-raspberrypi#82)](https://github.com/siderolabs/sbc-raspberrypi/issues/82)
- [cilium/cilium#43198 — related network stall](https://github.com/cilium/cilium/issues/43198)
- [rpi-6.18.y macb EEE PR #7270](https://github.com/raspberrypi/linux/pull/7270)
- [Patched kernel image comment (sbc-raspberrypi#91)](https://github.com/siderolabs/sbc-raspberrypi/issues/91#issuecomment-4316868066)
