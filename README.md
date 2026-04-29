# talos-rpi-builder

[![Build and Publish](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/publish.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/publish.yml)
[![Build Kernel](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/build-kernel.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/build-kernel.yml)
[![Build Overlay](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/build-overlay.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-builder/actions/workflows/build-overlay.yml)

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM4, CM5, Pi 4, and Pi 5** on CM4IO/CM5IO-compatible carrier boards (e.g. DeskPi Super6C).

Builds a single `rpi_generic` image that works across CM4, CM5, Pi 4, and Pi 5 boards.

The build pipeline is fully self-contained — the kernel (`ghcr.io/wheetazlab/rpi-talos`) is built from source via `build-kernel.yml`, using the standard `siderolabs/pkgs` kernel with three macb ethernet patches imported directly from `siderolabs/pkgs` main at commit [`9a718f6`](https://github.com/siderolabs/pkgs/commit/9a718f6a64aaeb260a9e5182c93817676beff270) (PR #1526 merge). The disk image is assembled by `publish.yml` using that kernel image plus a custom `sbc-raspberrypi` overlay (full BCM2712/RP1 U-Boot with NVMe/PCIe support, unified `rpi_generic` installer), `iscsi-tools`, and `util-linux-tools`.

## Background

Talos ≤ v1.12.x could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

NVMe boot support is provided by a patched U-Boot baked into the custom `sbc-raspberrypi` overlay, sourced from [sidero-community/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) by [@appkins](https://github.com/appkins). PR #88 replaces the old NVMe-only patch with 14 comprehensive BCM2712/RP1 patches and unifies CM4/CM5 into a single `rpi_generic` installer overlay.

> **Huge thanks to [@appkins](https://github.com/appkins) for [sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88).** That PR is the *entire* reason this repo can ship a **single unified `metal-arm64.raw.xz`** that boots on CM4, CM5, Pi 4, **and** Pi 5 — same kernel, same initramfs, same DTB set, no per-board variants. Before PR #88, each board needed its own overlay/installer. PR #88 collapses BCM2711 (CM4/Pi 4) and BCM2712 (CM5/Pi 5) support into one `rpi_generic` installer. Awesome work.

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

### CM5 microSD card-detect patch

The overlay build also injects [`patches/dtb/0011-cm5-sdio1-drop-broken-cd.patch`](patches/dtb/0011-cm5-sdio1-drop-broken-cd.patch), which removes `broken-cd;` from the `&sdio1` node in `bcm2712-rpi-cm5.dtsi`.

**Why:** upstream `broken-cd;` causes the kernel to set `MMC_CAP_NEEDS_POLL`, which prevents `mmc_rescan()` from short-circuiting on an empty microSD slot. The kernel issues `CMD52` (SDIO probe) into nothing, `sdhci_timeout_timer()` fires after ~10s, and the SDHCI register dump (`mmc0: Timeout waiting for hardware cmd interrupt`) repeats every ~10s for the lifetime of the system on NVMe-only boots.

The BCM2712 SDHCI controller has a working `SDHCI_CARD_PRESENT` bit and raises `SDHCI_INT_CARD_INSERT` / `REMOVE` on physical card transitions, so dropping `broken-cd;` silences the empty-slot loop while preserving hot-insert.

**Carrier compatibility:** verified on CM4IO, CM5IO, and DeskPi Super6C. Carriers that don't wire microSD CD to the controller's native CD pin would need `cd-gpios = <...>;` (or to keep `broken-cd`) and should not use this overlay.

The overlay build runs `patch --dry-run` against a fresh `raspberrypi/linux` checkout at `RPI_DTB_REF` to fail fast on context drift before invoking `make sbc-raspberrypi`.

### macb kernel patches

Three patches are applied to the standard Talos kernel (`patches/linux/`) to fix silent TX stall issues on PCIe-attached macb ethernet (BCM2712/RP1):

| Patch | Fix |
|-------|-----|
| `0001` | Flush PCIe posted write after TSTART doorbell |
| `0002` | Re-check ISR after IER re-enable in `macb_tx_poll` |
| `0003` | TX stall watchdog — defence-in-depth per-queue `delayed_work` |

These patches address [sbc-raspberrypi#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82) / [sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91) / [cilium#43198](https://github.com/cilium/cilium/issues/43198). The canonical source used by this repo is [siderolabs/pkgs PR #1526](https://github.com/siderolabs/pkgs/pull/1526) by [@lukaszraczylo](https://github.com/lukaszraczylo), pinned to its merge commit [`9a718f6`](https://github.com/siderolabs/pkgs/commit/9a718f6a64aaeb260a9e5182c93817676beff270) on `main`.

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
| Linux kernel          | standard `siderolabs/pkgs` mainline kernel + 3 macb patches |
| SBC overlay           | `ghcr.io/wheetazlab/sbc-raspberrypi:pr88-cd1` (PR #88 + CM5 sdio1 broken-cd drop) |
| iscsi-tools extension | `v0.2.0`       |
| util-linux-tools      | `2.41.2`       |
| Installer base        | `ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-macb` (built by `build-kernel.yml`) |

All versions are configurable — see [Customization](#customization).

---

## CI/CD

Images are built automatically on GitHub Actions using a native **Ubuntu arm64** runner — no cross-compilation needed.

All workflow files use `github.repository_owner` for all GHCR paths — they are fully portable. Forks automatically publish to the forker's own GHCR namespace.

### Build Patched Kernel (`build-kernel.yml`)

Builds the custom installer-base OCI image that `publish.yml` consumes. Run this first whenever you bump Talos or want to update the macb patches.

**Pipeline:**
1. Clones `siderolabs/pkgs` at `PKG_VERSION` (standard upstream kernel, no vendor fork)
2. Fetches the three macb patches from `siderolabs/pkgs` main at commit `9a718f6` (PR #1526 merge) into the pkgs kernel patch directory
3. Builds and pushes `ghcr.io/<owner>/kernel:<pkgs-tag>` using pkgs' native patch-and-build
4. Clones `siderolabs/talos` at `talos_version` (unmodified — no patches needed)
5. Builds and pushes `installer-base` with `PKG_KERNEL=` pointing to the macb-patched kernel OCI
6. `crane copy`s to `ghcr.io/<owner>/rpi-talos:<installer_tag>` (e.g. `v1.12.7-k-macb`)

**Trigger:** Actions → Build Patched Kernel Installer Base → Run workflow

**Inputs:**

| Input | Default | Description |
|-------|---------|-------------|
| `talos_version` | `v1.12.7` | Talos branch to build |
| `pkg_version` | `v1.12.0-58-g86d6af1` | `siderolabs/pkgs` ref (branch, tag, or git-describe) |
| `pkgs_macb_ref` | `9a718f6a64aaeb260a9e5182c93817676beff270` | `siderolabs/pkgs` commit SHA on `main` containing the three macb patches |
| `installer_tag` | `v1.12.7-k-macb` | Output image tag |

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

Manually-triggered workflow that builds and pushes `ghcr.io/<owner>/sbc-raspberrypi:<tag>` from the sidero-community PR #88 fork. Run this when PR #88 gets new commits, when local DTB patches in [`patches/dtb/`](patches/dtb/) change, or when PR #88 is merged upstream.

**Trigger:** Actions → Build Custom SBC Overlay → Run workflow

**Inputs:**
- `pr88_sha` — commit SHA in `sidero-community/sbc-raspberrypi` (default: PR #88 head)
- `overlay_tag` — image tag to publish (default: `pr88-cd1`)

Local DTB patches under [`patches/dtb/`](patches/dtb/) are copied into the overlay's `artifacts/dtb/raspberrypi/patches/` directory before `make sbc-raspberrypi`. They are applied alphabetically along with PR #88's own patches — the `0011-` prefix ensures local patches land after upstream's `0006-` (eMMC slow-down). A `patch --dry-run` against a fresh `raspberrypi/linux` checkout at `RPI_DTB_REF` runs first to fail fast on context drift.

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

Download from the [Releases page](https://github.com/wheetazlab/talos-rpi-builder/releases):

| File | For |
|------|-----|
| `metal-arm64.raw.xz` | CM4, CM5, Pi 4, Pi 5 (all variants) |

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

### Prerequisites: build kernel + overlay first

`build.sh` / `make build` pull `rpi-talos` and `sbc-raspberrypi` from GHCR. If you haven't pushed them yet (or want to rebuild with new patches), run the local build scripts first:

```bash
# 1. Build macb-patched kernel + installer-base → ghcr.io/<org>/rpi-talos:<tag>
./scripts/build-kernel.sh

# 2. Build sbc-raspberrypi overlay → ghcr.io/<org>/sbc-raspberrypi:pr88-cd1
./scripts/build-overlay.sh
```

Both scripts require:
- Docker or Podman **logged in** to GHCR (`docker login ghcr.io -u <user>`)
- `crane` installed (`brew install crane` or `go install github.com/google/go-containerregistry/cmd/crane@latest`)

Override defaults with env vars or flags:

```bash
# build-kernel.sh options
GHCR_ORG=myorg TALOS_VERSION=v1.12.7 PKG_VERSION=v1.12.0-58-g86d6af1 INSTALLER_TAG=v1.12.7-k-macb \
  ./scripts/build-kernel.sh

# override patch source ref if needed
GHCR_ORG=myorg TALOS_VERSION=v1.12.7 PKG_VERSION=v1.12.0-58-g86d6af1 PKGS_MACB_REF=9a718f6a64aaeb260a9e5182c93817676beff270 INSTALLER_TAG=v1.12.7-k-macb \
  ./scripts/build-kernel.sh

# build-overlay.sh options
GHCR_ORG=myorg OVERLAY_TAG=pr88 ./scripts/build-overlay.sh

# keep Talos kernel as-is, but pin overlay internals for CM5
GHCR_ORG=myorg OVERLAY_TAG=pr88-cm5 \
UBOOT_VERSION=2026.01 \
UBOOT_SHA256=b60d5865cefdbc75da8da4156c56c458e00de75a49b80c1a2e58a96e30ad0d54 \
RPI_DTB_REF=f2f68e79f16f \
./scripts/build-overlay.sh

# explicitly control Pi5 one-shot SD poll behavior
GHCR_ORG=myorg OVERLAY_TAG=pr88-cm5 PI5_SD_POLL_ONCE=true ./scripts/build-overlay.sh

# Both scripts accept --help for full option list
./scripts/build-kernel.sh --help
./scripts/build-overlay.sh --help
```

`build-overlay.sh` overrides affect only the `sbc-raspberrypi` overlay (U-Boot + DTBs). They do **not** switch Talos to the Raspberry Pi kernel.

`UBOOT_VERSION`/`UBOOT_SHA*` refer to upstream `u-boot/u-boot` source tarballs (`u-boot-<ver>.tar.bz2` from `ftp.denx.de`), not prebuilt image checksums.

### Build disk image (after kernel+overlay are in GHCR)

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
make build CUSTOM_OVERLAY_IMAGE=ghcr.io/wheetazlab/sbc-raspberrypi:pr88-cd1

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

- Talos Linux kernel + initramfs (arm64) — from `ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-macb` (standard `siderolabs/pkgs` mainline kernel, built by `build-kernel.yml` with 3 macb patches applied)
- **Patched U-Boot** (BCM2712/RP1) from `ghcr.io/wheetazlab/sbc-raspberrypi:pr88` (PR #88 patch set — NVMe/PCIe, EEE LPI, MACB driver)
- DTBs from custom `sbc-raspberrypi` overlay (`rpi_generic` installer):
  - `bcm2711-rpi-4-b.dtb` ← Pi 4 Model B
  - `bcm2711-rpi-cm4.dtb` ← CM4 (CM4IO and compatible carriers)
  - `bcm2712-rpi-cm5-cm4io.dtb` ← CM4IO-compatible carriers (e.g. DeskPi Super6C)
  - `bcm2712-rpi-cm5-cm5io.dtb`
  - `bcm2712-rpi-cm5l-cm4io.dtb`
  - `bcm2712-rpi-cm5l-cm5io.dtb`
  - `bcm2712-rpi-5-b.dtb`
  - `bcm2712d0-rpi-5-b.dtb`
- System extension: `iscsi-tools v0.2.0`
- System extension: `util-linux-tools 2.41.2`
- Kernel arg: _(none — single image supports all CM4/CM5/Pi 4/Pi 5 variants)

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
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-installer:v1.12.7-k-macb
```

---

## References

**Talos / SBC**
- [Talos Linux docs — SBC support](https://www.talos.dev/v1.12/talos-guides/install/single-board-computers/)
- [sbc-raspberrypi releases](https://github.com/siderolabs/sbc-raspberrypi/releases)
- [BCM2712/RP1 U-Boot + NVMe (sbc-raspberrypi PR #88)](https://github.com/siderolabs/sbc-raspberrypi/pull/88) by [@appkins](https://github.com/appkins)
- [CM5 boot issue fix (sbc-raspberrypi#79)](https://github.com/siderolabs/sbc-raspberrypi/pull/79)
- [Original boot issue (talos#12748)](https://github.com/siderolabs/talos/issues/12748)
- [Talos system extensions](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [DeskPi Super6C](https://deskpi.com/products/deskpi-super6c-raspberry-pi-cm4-6-boards-cluster-mini-itx-board) — example CM4IO-compatible carrier board

**Issue 91 / vendor-kernel / macb patches**
- [macb TX stall tracking issue (sbc-raspberrypi#82)](https://github.com/siderolabs/sbc-raspberrypi/issues/82)
- [cilium/cilium#43198 — related network stall](https://github.com/cilium/cilium/issues/43198)
- [rpi-6.18.y macb EEE PR #7270](https://github.com/raspberrypi/linux/pull/7270)
- [Patched kernel image comment (sbc-raspberrypi#91)](https://github.com/siderolabs/sbc-raspberrypi/issues/91#issuecomment-4316868066)
- [siderolabs/pkgs PR #1526 — macb TX stall fixes](https://github.com/siderolabs/pkgs/pull/1526) by [@lukaszraczylo](https://github.com/lukaszraczylo)

## Credits

Upstream contributors whose work this repo packages:

- [@appkins](https://github.com/appkins) — [siderolabs/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) (BCM2712/RP1 U-Boot + NVMe boot, `rpi_generic` overlay supporting CM4/CM5/Pi 4/Pi 5)
- [@lukaszraczylo](https://github.com/lukaszraczylo) — [siderolabs/pkgs PR #1526](https://github.com/siderolabs/pkgs/pull/1526) (3× `net: macb` TX stall fixes for the BCM2712 PCIe Ethernet controller)
