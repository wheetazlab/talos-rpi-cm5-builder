#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# inject-uboot.sh — Inject patched u-boot.bin into the Talos disk image file
#
# Operates on _out/metal-arm64.raw.xz — no physical disk needed.
# Decompresses the image, mounts the FAT32 boot partition, replaces u-boot.bin,
# then recompresses. Works on macOS (hdiutil/diskutil) and Linux (losetup/mount).
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
echo " OS      : $(uname -s)"
echo "============================================================"
echo ""

# --- Decompress ---------------------------------------------------------------
echo "==> Decompressing ${XZ_IMAGE}..."
xz -dk "${XZ_IMAGE}"   # -k keeps the .xz, -d decompresses → .raw

# --- Mount + inject (OS-specific) ---------------------------------------------
if [[ "$(uname -s)" == "Darwin" ]]; then
  # macOS: hdiutil + diskutil
  echo "==> Attaching image (macOS)..."
  ATTACH_OUT=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage \
    -nomount "${RAW_IMAGE}" 2>&1)
  echo "${ATTACH_OUT}"
  BASE_DEV=$(echo "${ATTACH_OUT}" | grep -oE '/dev/disk[0-9]+' | head -1)
  [[ -z "${BASE_DEV}" ]] && { echo "ERROR: Could not attach image."; rm -f "${RAW_IMAGE}"; exit 1; }
  BOOT_PART="${BASE_DEV}s1"
  diskutil mount "${BOOT_PART}"
  MOUNT=$(diskutil info "${BOOT_PART}" | awk '/Mount Point/{print $NF}')
  [[ -z "${MOUNT}" ]] && { echo "ERROR: Could not mount ${BOOT_PART}."; hdiutil detach "${BASE_DEV}" 2>/dev/null || true; rm -f "${RAW_IMAGE}"; exit 1; }
  echo "==> Mounted at: ${MOUNT}"
  _inject() { cp "${UBOOT_BIN}" "${MOUNT}/u-boot.bin"; sync; }
  _cleanup() { diskutil unmount "${BOOT_PART}" 2>/dev/null || true; hdiutil detach "${BASE_DEV}" 2>/dev/null || true; }

else
  # Linux: losetup + mount
  echo "==> Attaching image (Linux)..."
  LOOP_DEV=$(sudo losetup --find --show --partscan "${RAW_IMAGE}")
  echo "==> Loop device: ${LOOP_DEV}"
  sleep 1   # let the kernel settle partition nodes
  BOOT_PART="${LOOP_DEV}p1"
  MOUNT=$(mktemp -d)
  echo "==> Mounting ${BOOT_PART} at ${MOUNT}..."
  sudo mount "${BOOT_PART}" "${MOUNT}"
  _inject() { sudo cp "${UBOOT_BIN}" "${MOUNT}/u-boot.bin"; sudo sync; }
  _cleanup() { sudo umount "${MOUNT}" 2>/dev/null || true; sudo losetup -d "${LOOP_DEV}" 2>/dev/null || true; rmdir "${MOUNT}" 2>/dev/null || true; }
fi

# --- Inject -------------------------------------------------------------------
if [[ ! -f "${MOUNT}/u-boot.bin" ]]; then
  echo "ERROR: ${MOUNT}/u-boot.bin not found — unexpected partition layout?"
  _cleanup; rm -f "${RAW_IMAGE}"; exit 1
fi

echo "==> Current u-boot.bin: $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"
echo "==> Replacing with NVMe-capable build..."
_inject
echo "==> New u-boot.bin:     $(ls -lh "${MOUNT}/u-boot.bin" | awk '{print $5, $6, $7, $8}')"

# --- Detach -------------------------------------------------------------------
echo "==> Unmounting and detaching image..."
_cleanup

# --- Recompress ---------------------------------------------------------------
echo "==> Recompressing to ${XZ_IMAGE}..."
rm -f "${XZ_IMAGE}"
xz -T0 "${RAW_IMAGE}"   # -T0 = all threads; outputs .raw.xz, removes .raw

echo ""
echo "==> Done: $(ls -lh "${XZ_IMAGE}")"
