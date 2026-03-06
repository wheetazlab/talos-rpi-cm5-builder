# talos-rpi-cm5-builder

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM5** on the **DeskPi Super6C** cluster board.

Includes the `iscsi-tools` system extension and uses the latest `sbc-raspberrypi` overlay which adds proper DTB support for CM5 (including D0-stepping boards — Rev 1.1).

## Background

Talos ≤ v1.12.2 could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

---

## ⚠️ Important: NVMe Boot Not Supported

CM5 **cannot boot from NVMe** yet — this is a U-Boot limitation, not a Talos limitation. You **must** boot from **eMMC or SD card**. You can use NVMe as data/storage after boot.

---

## Versions

| Component             | Version   |
|-----------------------|-----------|
| Talos Linux           | `v1.12.4` |
| sbc-raspberrypi       | `v0.2.0`  |
| iscsi-tools extension | `v1.12.4` |
| util-linux-tools      | `2.41.2`  |

All versions are configurable — see [Customization](#customization).

---

## Prerequisites

- **Docker** (with privileged container support)
- **macOS or Linux** host
- `make` (standard on macOS/Linux)
- For eMMC flashing: `rpiboot` ([install instructions](https://github.com/raspberrypi/usbboot))

---

## Quick Start

### 1. Build the image

```bash
make build
```

This runs the Talos imager in Docker and writes `_out/metal-arm64.raw`.

Or use the script directly:

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

### 2. Flash to SD card

```bash
# Find your disk first (macOS)
diskutil list

# Flash (replace disk4 with your SD card)
make flash-sd DISK=/dev/disk4
```

Manual equivalent:
```bash
sudo dd if=_out/metal-arm64.raw of=/dev/disk4 conv=fsync bs=4M status=progress
sudo sync
```

### 3. Flash to eMMC (via rpiboot)

The Super6C has a switch to put the CM5 into USB mass-storage mode for flashing eMMC.

1. Set the CM5 module into `nRPiBOOT` / USB boot mode (check the Super6C manual — usually a jumper or button)
2. Connect the Super6C to your Mac via USB-C
3. Run `rpiboot` to expose the eMMC as a disk:
   ```bash
   sudo rpiboot
   ```
4. The eMMC will appear as a disk (e.g. `/dev/disk5`). Flash it:
   ```bash
   make flash-sd DISK=/dev/disk5
   ```
   > Note: `flash-sd` target works for any block device, including eMMC.
5. Set the module back to normal boot mode and power on.

> **Tip:** One confirmed working approach (from the community) is to flash **Raspberry Pi OS Lite** first, then re-flash with the Talos image. This updates the bootloader EEPROM which can prevent a hang at the U-Boot logo.

---

## Customization

Override versions at build time:

```bash
# Use a different Talos version
make build TALOS_VERSION=v1.12.5

# Pin specific sbc-raspberrypi version
make build SBC_RPI_VERSION=v0.1.9

# Full override example
make build TALOS_VERSION=v1.12.5 SBC_RPI_VERSION=v0.2.0 ISCSI_TOOLS_VERSION=v1.12.5
```

Or with the shell script:
```bash
./scripts/build.sh --talos v1.12.5 --sbc v0.2.0
```

### Adding more extensions

Edit the `Makefile` and append additional `--system-extension-image` flags to the Docker command:

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
make flash-sd       Flash image to disk (requires DISK=/dev/sdX)
make pull-images    Pre-pull all required Docker images
make clean          Remove _out/ directory
make help           Show all targets and version variables
```

---

## What's in the image?

The Talos imager produces a `metal-arm64.raw` that contains:

- Talos Linux kernel + initramfs (arm64)
- U-Boot bootloader for RPI CM5
- DTBs compiled from the Raspberry Pi kernel with openSUSE patches:
  - `bcm2712-rpi-cm5-cm5io.dtb`
  - `bcm2712-rpi-cm5-cm4io.dtb` ← used by Super6C
  - `bcm2712-rpi-cm5l-cm4io.dtb`
  - `bcm2712-rpi-cm5l-cm5io.dtb`
  - `bcm2712-rpi-5-b.dtb`
  - `bcm2712d0-rpi-5-b.dtb`
- System extension: `iscsi-tools`
- System extension: `util-linux-tools`

---

## After Booting

Talos will enter **maintenance mode** waiting for a machine config. Apply a config with `talosctl`:

```bash
# Generate a config (replace DOMAIN and IPs as needed)
talosctl gen config my-cluster https://<CONTROLPLANE_IP>:6443 \
  --additional-sans <CONTROLPLANE_IP>

# Apply to the node (still in maintenance mode)
talosctl apply-config --insecure --nodes <NODE_IP> --file controlplane.yaml \
  --talosconfig talosconfig

# Bootstrap etcd (first control-plane node only)
talosctl bootstrap --nodes <CONTROLPLANE_IP> --talosconfig talosconfig

# Get kubeconfig
talosctl kubeconfig --nodes <CONTROLPLANE_IP> --talosconfig talosconfig
```

---

## References

- [Talos Linux docs — SBC support](https://www.talos.dev/v1.12/talos-guides/install/single-board-computers/)
- [sbc-raspberrypi releases](https://github.com/siderolabs/sbc-raspberrypi/releases)
- [Talos system extensions](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [CM5 boot issue fix (sbc-raspberrypi#79)](https://github.com/siderolabs/sbc-raspberrypi/pull/79)
- [Original boot issue (talos#12748)](https://github.com/siderolabs/talos/issues/12748)
- [DeskPi Super6C](https://deskpi.com/products/deskpi-super6c-raspberry-pi-cm4-6-boards-cluster-mini-itx-board)
