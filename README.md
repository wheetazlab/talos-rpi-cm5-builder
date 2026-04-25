# talos-rpi-cm5-builder

[![Build and Publish](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml)

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM4, CM5, and Pi 5** on CM4IO/CM5IO-compatible carrier boards (e.g. DeskPi Super6C).

Builds a single `rpi_generic` image that works across CM4, CM5, and Pi 5 boards.

Current build path uses the prebuilt issue-91 Raspberry Pi vendor-kernel installer image `ghcr.io/lukaszraczylo/rpi-talos:v1.12.6-k-6.18.24-macb` as the Talos base installer, plus a custom `sbc-raspberrypi` overlay built from the [sidero-community/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) fork (full BCM2712/RP1 U-Boot with NVMe/PCIe support + unified `rpi_generic` installer), `iscsi-tools`, and `util-linux-tools`.

## Background

Talos ≤ v1.12.2 could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

NVMe boot support is provided by a patched U-Boot baked into the custom `sbc-raspberrypi` overlay, sourced from [sidero-community/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88). PR #88 replaces the old NVMe-only patch with 14 comprehensive BCM2712/RP1 patches and unifies CM4/CM5 into a single `rpi_generic` installer overlay.

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

The kernel/network fixes from issue `#91` come from that prebuilt installer base, not from patch files stored in this repo.

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
| Talos Linux           | `v1.12.6`      |
| SBC overlay           | `ghcr.io/wheetazlab/sbc-raspberrypi:pr88` (PR #88 — BCM2712/RP1 U-Boot + NVMe) |
| iscsi-tools extension | `v0.2.0`       |
| util-linux-tools      | `2.41.2`       |
| Installer base        | `ghcr.io/lukaszraczylo/rpi-talos:v1.12.6-k-6.18.24-macb` |

All versions are configurable — see [Customization](#customization).

---

## CI/CD

Images are built automatically on GitHub Actions using a native **Ubuntu arm64** runner — no cross-compilation needed.

Both workflow files use `github.repository_owner` for all GHCR paths — they are fully portable. Forks automatically publish to the forker's own GHCR namespace.

### Build and Publish (`publish.yml`)

The standard image build pipeline. Builds disk images and the upgrade installer for both CM5 variants.

**Triggers:**
- Push a version tag (e.g. `git tag v1.12.6 && git push --tags`) → full build + publish
- Manual run via **Actions → Build and Publish → Run workflow** with optional version override

**Pipeline jobs:**
1. **`resolve-version`** — resolves Talos version from tag/input/Makefile default; reads `CUSTOM_OVERLAY_IMAGE` from Makefile
2. **`build` (matrix: `lite` + `emmc`)** — both variants build in parallel:
   - Builds disk image and installer (overlay baked in via `--overlay-image`)
   - Pushes installer to GHCR tagged `:vX.Y.Z-rpi-kernel-lite` / `:vX.Y.Z-rpi-kernel-emmc`
   - Uploads `metal-arm64-lite.raw.xz` / `metal-arm64-emmc.raw.xz` as artifacts
3. **`release`** — downloads both artifacts and creates the GitHub release with both images attached

The workflow uses the stock Talos imager with the prebuilt installer base `ghcr.io/lukaszraczylo/rpi-talos:v1.12.6-k-6.18.24-macb` and the custom overlay `ghcr.io/wheetazlab/sbc-raspberrypi:pr88`.

### Build Custom Overlay (`build-overlay.yml`)

Manually-triggered workflow that builds and pushes `ghcr.io/<owner>/sbc-raspberrypi:<tag>` from the sidero-community PR #88 fork. Run this when you want to update the overlay (e.g. PR #88 gets new commits or is merged upstream).

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
make publish TALOS_VERSION=v1.12.6

# Override overlay image
make publish CUSTOM_OVERLAY_IMAGE=ghcr.io/wheetazlab/sbc-raspberrypi:pr88
```

### Adding more extensions

Edit the `Makefile` and append additional `--system-extension-image` flags:

```makefile
--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
--system-extension-image="ghcr.io/siderolabs/gvisor:20260202.0" \
```

Browse available extensions: https://github.com/siderolabs/extensions

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

- Talos Linux kernel + initramfs (arm64) — from `ghcr.io/lukaszraczylo/rpi-talos:v1.12.6-k-6.18.24-macb` (Raspberry Pi vendor kernel path)
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
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.6-rpi-kernel
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

**Issue 91 / vendor-kernel path**
- [Patched kernel image comment](https://github.com/siderolabs/sbc-raspberrypi/issues/91#issuecomment-4316868066)
- [Network issues tracking issue (sbc-raspberrypi#82)](https://github.com/siderolabs/sbc-raspberrypi/issues/82)
- [rpi-6.18.y macb EEE PR #7270](https://github.com/raspberrypi/linux/pull/7270)
