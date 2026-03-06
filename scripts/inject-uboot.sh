#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inject-uboot.sh — Replace u-boot.bin on a flashed SD/eMMC with the patched
#                   NVMe-capable build from _out/u-boot-nvme.bin
#
# Must be run AFTER flashing the Talos image (make flash-sd).
# macOS will auto-mount the FAT32 boot partition after flashing.
#
# Usage:
#   ./scripts/inject-uboot.sh /dev/rdisk4
#   make uboot-inject DISK=/dev/rdisk4
# ------------------------------------------------------------------------------

set -euo pipefail

DISK="${1:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_DIR}/_out"
UBOOT_BIN="${OUT_DIR}/u-boot-nvme.bin"

# --- Pre-flight ---------------------------------------------------------------
if [[ -z "${DISK}" ]]; then
  echo "ERROR: Disk argument required."
  echo "Usage: $0 /dev/rdisk4"
  exit 1
fi

if [[ ! -f "${UBOOT_BIN}" ]]; then
  echo "ERROR: ${UBOOT_BIN} not found."
  echo "Run 'make uboot-build' first."
  exit 1
fi

# Derive partition device: /dev/rdisk4 -> /dev/disk4s1
BASE_DISK="${DISK/rdisk/disk}"
BOOT_PART="${BASE_DISK}s1"

echo "============================================================"
echo " U-Boot NVMe Inject"
echo "============================================================"
echo " Source  : ${UBOOT_BIN}"
echo " Disk    : ${DISK}"
echo " Boot partition: ${BOOT_PART}"
echo "============================================================"
echo ""

# Unmount if already mounted
echo "==> Unmounting ${BOOT_PART} (if mounted)..."
diskutil unmount "${BOOT_PART}" 2>/dev/null || true

# Mount the boot partition
echo "==> Mounting ${BOOT_PART}..."
diskutil mount "${BOOT_PART}"

# Get mount point
MOUNT=$(diskutil info "${BOOT_PART}" | grep "Mount Point" | awk '{print $NF}')

if [[ -z "${MOUNT}" ]]; then
  echo "ERROR: Could not determine mount point for ${BOOT_PART}"
  exit 1
fi

echo "==> Mounted at: ${MOUNT}"

# Verify it looks like a Talos boot partition
if [[ ! -f "${MOUNT}/u-boot.bin" ]]; then
  echo "ERROR: ${MOUNT}/u-boot.bin not found — is this the right disk/partition?"
  diskutil unmount "${BOOT_PART}" 2>/dev/null || true
  exit 1
fi

echo "==> Current u-boot.bin: $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"
echo "==> Replacing with NVMe-capable build..."
cp "${UBOOT_BIN}" "${MOUNT}/u-boot.bin"
sync

echo "==> New u-boot.bin:     $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"

echo "==> Unmounting ${BOOT_PART}..."
diskutil unmount "${BOOT_PART}"

echo ""
echo "==> Done! Boot partition updated with NVMe-capable U-Boot."
echo "    Your CM5 should now be able to boot Talos from NVMe."
