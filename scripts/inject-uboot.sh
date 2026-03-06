#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inject-uboot.sh — Inject patched u-boot.bin into the Talos disk image file
#
# Operates on _out/metal-arm64.raw.xz — no physical disk needed.
# Decompresses the image, mounts the FAT32 boot partition via hdiutil,
# replaces u-boot.bin, then recompresses.
#
# Must be run AFTER:
#   make build        (_out/metal-arm64.raw.xz exists)
#   make uboot-build  (_out/u-boot-nvme.bin exists)
#
# Usage:
#   ./scripts/inject-uboot.sh
#   make uboot-inject
# ------------------------------------------------------------------------------

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_DIR}/_out"
ARCH="${ARCH:-arm64}"
XZ_IMAGE="${OUT_DIR}/metal-${ARCH}.raw.xz"
RAW_IMAGE="${OUT_DIR}/metal-${ARCH}.raw"
UBOOT_BIN="${OUT_DIR}/u-boot-nvme.bin"

# --- Pre-flight ---------------------------------------------------------------
if [[ ! -f "${XZ_IMAGE}" ]]; then
  echo "ERROR: ${XZ_IMAGE} not found. Run 'make build' first."
  exit 1
fi

if [[ ! -f "${UBOOT_BIN}" ]]; then
  echo "ERROR: ${UBOOT_BIN} not found. Run 'make uboot-build' first."
  exit 1
fi

echo "============================================================"
echo " U-Boot NVMe Inject → Image"
echo "============================================================"
echo " Image   : ${XZ_IMAGE}"
echo " U-Boot  : ${UBOOT_BIN}"
echo "============================================================"
echo ""

# --- Decompress ---------------------------------------------------------------
echo "==> Decompressing ${XZ_IMAGE}..."
xz -dk "${XZ_IMAGE}"   # -k keeps the .xz, -d decompresses → .raw

# --- Attach image -------------------------------------------------------------
echo "==> Attaching image..."
HDIUTIL_OUT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  -nomount "${RAW_IMAGE}" 2>&1)
echo "${HDIUTIL_OUT}"

# Extract the base disk device (e.g. /dev/disk5)
BASE_DEV=$(echo "${HDIUTIL_OUT}" | grep -oE '/dev/disk[0-9]+' | head -1)
if [[ -z "${BASE_DEV}" ]]; then
  echo "ERROR: Could not determine attached disk device."
  rm -f "${RAW_IMAGE}"
  exit 1
fi
BOOT_PART="${BASE_DEV}s1"

# --- Mount boot partition -----------------------------------------------------
echo "==> Mounting boot partition ${BOOT_PART}..."
MOUNT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage \
  "${RAW_IMAGE}" -section 1 2>/dev/null \
  | grep -oE '/Volumes/.*' | head -1 || true)

# Fallback: mount the slice directly
if [[ -z "${MOUNT}" ]]; then
  diskutil mount "${BOOT_PART}"
  MOUNT=$(diskutil info "${BOOT_PART}" | grep "Mount Point" | awk '{print $NF}')
fi

if [[ -z "${MOUNT}" ]]; then
  echo "ERROR: Could not mount ${BOOT_PART}."
  hdiutil detach "${BASE_DEV}" 2>/dev/null || true
  rm -f "${RAW_IMAGE}"
  exit 1
fi

echo "==> Mounted at: ${MOUNT}"

# --- Inject -------------------------------------------------------------------
if [[ ! -f "${MOUNT}/u-boot.bin" ]]; then
  echo "ERROR: ${MOUNT}/u-boot.bin not found — unexpected partition layout?"
  diskutil unmount "${BOOT_PART}" 2>/dev/null || true
  hdiutil detach "${BASE_DEV}" 2>/dev/null || true
  rm -f "${RAW_IMAGE}"
  exit 1
fi

echo "==> Current u-boot.bin: $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"
echo "==> Replacing with NVMe-capable build..."
cp "${UBOOT_BIN}" "${MOUNT}/u-boot.bin"
sync

echo "==> New u-boot.bin:     $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"

# --- Detach -------------------------------------------------------------------
echo "==> Unmounting and detaching image..."
diskutil unmount "${BOOT_PART}" 2>/dev/null || true
hdiutil detach "${BASE_DEV}"

# --- Recompress ---------------------------------------------------------------
echo "==> Recompressing to ${XZ_IMAGE}..."
rm -f "${XZ_IMAGE}"
xz -T0 "${RAW_IMAGE}"   # -T0 = all threads; outputs .raw.xz, removes .raw

echo ""
echo "==> Done: $(ls -lh "${XZ_IMAGE}")"

echo ""
echo "==> Done! Boot partition updated with NVMe-capable U-Boot."
echo "    Your CM5 should now be able to boot Talos from NVMe."
