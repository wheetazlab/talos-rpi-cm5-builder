# talos-rpi-cm5-builder

[![Build and Publish](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml)

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM5** on the **DeskPi Super6C** cluster board.

Includes a patched U-Boot with NVMe/PCIe support, `iscsi-tools` and `util-linux-tools` system extensions, and the latest `sbc-raspberrypi` overlay with proper DTB support for CM5 (including D0-stepping / Rev 1.1 boards).

## Background

Talos ≤ v1.12.2 could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

NVMe boot support is provided by a patched U-Boot (`v2026.04-rc1`) with BCM2712 PCIe driver support, contributed by [@appkins](https://github.com/appkins) via [siderolabs/sbc-raspberrypi#81](https://github.com/siderolabs/sbc-raspberrypi/issues/81).

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

---

## Versions

| Component             | Version        |
|-----------------------|----------------|
| Talos Linux           | `v1.12.4`      |
| sbc-raspberrypi       | `v0.2.0`       |
| iscsi-tools extension | `v0.2.0`       |
| util-linux-tools      | `2.41.2`       |
| U-Boot                | `v2026.04-rc1` |

All versions are configurable — see [Customization](#customization).

---

## CI/CD

Images are built automatically on GitHub Actions using a native **Ubuntu arm64** runner — no cross-compilation needed.

**Triggers:**
- Push a version tag (e.g. `git tag v1.12.4 && git push --tags`) → full build + publish
- Manual run via **Actions → Build and Publish → Run workflow** with optional version override

**Pipeline jobs:**
1. **`resolve-version`** — resolves Talos version from tag/input/Makefile default; extracts extension metadata
2. **`build-uboot`** — builds the patched U-Boot binary once and caches it as an artifact
3. **`build` (matrix: `lite` + `emmc`)** — both variants build in parallel:
   - Downloads the pre-built U-Boot artifact
   - Builds disk image, injects U-Boot, builds installer
   - Pushes installer to GHCR tagged `:vX.Y.Z-lite` / `:vX.Y.Z-emmc`
   - Uploads `metal-arm64-lite.raw.xz` / `metal-arm64-emmc.raw.xz` as artifacts
4. **`release`** — downloads both artifacts and creates the GitHub release with both images attached

---

## Prerequisites (local builds only)

- **Podman** or **Docker** (with privileged container support)
- **macOS** or **Linux** host (arm64 recommended for U-Boot build)
- `make`
- `gh` CLI for publishing: `brew install gh && gh auth login`

---

## Quick Start

### Download a release

Download from the [Releases page](https://github.com/wheetazlab/talos-rpi-cm5-builder/releases) — two variants are published per release:

| File | For |
|------|-----|
| `metal-arm64-lite.raw.xz` | CM5 Lite (no onboard eMMC) |
| `metal-arm64-emmc.raw.xz` | CM5 with onboard eMMC |

### Flash to SD card / eMMC

```bash
# macOS (replace <variant> with lite or emmc)
xzcat metal-arm64-<variant>.raw.xz | sudo dd of=/dev/rdiskN bs=4m

# Linux
xzcat metal-arm64-<variant>.raw.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

Or with make (after building locally):
```bash
make flash-sd DISK=/dev/rdisk4
```

### eMMC via rpiboot

1. Set the CM5 into USB boot mode (check the Super6C manual for the jumper/button)
2. Connect via USB-C and run `sudo rpiboot`
3. Flash to the exposed eMMC disk

> **Tip:** Flash Raspberry Pi OS first if CM5 hangs at the U-Boot logo — this updates the bootloader EEPROM.

---

## Local Build

```bash
# Full pipeline (build image + U-Boot + inject + installer + push + release)
make publish

# Individual steps
make build        # Talos disk image → _out/metal-arm64.raw.xz
make uboot-build  # Patched U-Boot  → _out/u-boot-nvme.bin
make uboot-inject # Inject U-Boot into disk image
make installer    # Installer OCI   → _out/installer-arm64.tar
make release      # GitHub release with .raw.xz artifact
```

---

## Customization

```bash
# Different Talos version
make publish TALOS_VERSION=v1.12.4

# CM5 with onboard eMMC (disables sdhci_brcmstb blacklist)
make publish CM5_VARIANT=emmc

# Full override
make publish TALOS_VERSION=v1.12.4 SBC_RPI_VERSION=v0.2.0 CM5_VARIANT=lite
```

**`CM5_VARIANT`** controls a kernel arg applied at image build time (local builds only — CI always builds both):
- `lite` (default) — blacklists `sdhci_brcmstb` to suppress spurious `mmc0` interrupt timeout errors on CM5 Lite (no onboard eMMC)
- `emmc` — no blacklist, eMMC controller stays active

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
make uboot-build    Build patched U-Boot with NVMe/PCIe support
make uboot-inject   Inject patched U-Boot into disk image
make uboot          Build + inject in one step
make installer      Build the Talos installer image (for talosctl upgrade)
make publish        Full pipeline: build → uboot → inject → installer → push → release
make flash-sd       Flash image to disk (requires DISK=/dev/rdiskN)
make pull-images    Pre-pull all required container images
make clean          Remove _out/ directory
make help           Show all targets and version variables
```

---

## What's in the image?

- Talos Linux kernel + initramfs (arm64)
- **Patched U-Boot** (`v2026.04-rc1`) with BCM2712 PCIe driver — enables NVMe boot on CM5
- DTBs from `sbc-raspberrypi v0.2.0`:
  - `bcm2712-rpi-cm5-cm4io.dtb` ← used by DeskPi Super6C
  - `bcm2712-rpi-cm5-cm5io.dtb`
  - `bcm2712-rpi-cm5l-cm4io.dtb`
  - `bcm2712-rpi-cm5l-cm5io.dtb`
  - `bcm2712-rpi-5-b.dtb`
  - `bcm2712d0-rpi-5-b.dtb`
- System extension: `iscsi-tools v0.2.0`
- System extension: `util-linux-tools 2.41.2`
- Kernel arg: `module_blacklist=sdhci_brcmstb` (`-lite` variant only)

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

To upgrade an existing node, use the installer image matching your variant:

```bash
# CM5 Lite
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.4-lite

# CM5 with eMMC
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.4-emmc
```

---

## References

- [Talos Linux docs — SBC support](https://www.talos.dev/v1.12/talos-guides/install/single-board-computers/)
- [sbc-raspberrypi releases](https://github.com/siderolabs/sbc-raspberrypi/releases)
- [NVMe boot patch (sbc-raspberrypi#81)](https://github.com/siderolabs/sbc-raspberrypi/issues/81)
- [CM5 boot issue fix (sbc-raspberrypi#79)](https://github.com/siderolabs/sbc-raspberrypi/pull/79)
- [Original boot issue (talos#12748)](https://github.com/siderolabs/talos/issues/12748)
- [Talos system extensions](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [DeskPi Super6C](https://deskpi.com/products/deskpi-super6c-raspberry-pi-cm4-6-boards-cluster-mini-itx-board)
