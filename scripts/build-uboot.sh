#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# build-uboot.sh — Build a patched U-Boot for RPi5/CM5 with NVMe/PCIe support
#
# Runs a native arm64 Ubuntu container — no cross-compiler needed on macOS M4.
# Applies patches/uboot-rpi5-nvme.patch which adds:
#   - BCM2712 PCIe driver support
#   - NVMe boot target
#   - RP1 southbridge init (ethernet in U-Boot)
#   - CM5 board type detection
#
# Output: _out/u-boot-nvme.bin
# Usage:
#   ./scripts/build-uboot.sh
#   UBOOT_VERSION=v2026.04-rc1 ./scripts/build-uboot.sh
# ------------------------------------------------------------------------------

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_DIR}/_out"
PATCH="${REPO_DIR}/patches/uboot-rpi5-nvme.patch"
UBOOT_VERSION="${UBOOT_VERSION:-v2026.04-rc1}"
DOCKER="${DOCKER:-podman}"

# --- Pre-flight ---------------------------------------------------------------
if [[ ! -f "${PATCH}" ]]; then
  echo "ERROR: ${PATCH} not found."
  exit 1
fi

mkdir -p "${OUT_DIR}"

echo "============================================================"
echo " U-Boot NVMe Build"
echo "============================================================"
echo " Container runtime : ${DOCKER}"
echo " U-Boot version    : ${UBOOT_VERSION}"
echo " Patch             : patches/uboot-rpi5-nvme.patch"
echo " Output            : _out/u-boot-nvme.bin"
echo " Host arch         : arm64 (native — no cross-compiler)"
echo "============================================================"
echo ""

"${DOCKER}" run --rm \
  -v "${OUT_DIR}:/out" \
  -v "${PATCH}:/patch.patch:ro" \
  ubuntu:24.04 bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    echo "==> Installing build deps..."
    apt-get update -qq
    apt-get install -qq -y \
      gcc make bison flex \
      python3 python3-setuptools python3-pyelftools \
      swig libssl-dev libgnutls28-dev bc \
      device-tree-compiler \
      git ca-certificates

    echo "==> Cloning U-Boot '"${UBOOT_VERSION}"'..."
    git clone --depth=1 --branch '"${UBOOT_VERSION}"' \
      https://github.com/u-boot/u-boot /uboot

    cd /uboot

    echo "==> Applying NVMe/PCIe patch..."
    git apply /patch.patch

    echo "==> Configuring rpi_5_defconfig..."
    make rpi_5_defconfig

    echo "==> Building (native arm64, $(nproc) threads)..."
    make -j$(nproc) u-boot.bin

    cp u-boot.bin /out/u-boot-nvme.bin
    echo ""
    echo "==> Done:"
    ls -lh /out/u-boot-nvme.bin
  '

echo ""
echo "==> u-boot-nvme.bin ready in _out/"
echo ""
echo "Next steps:"
echo "  1. Flash Talos:  make flash-sd DISK=/dev/rdisk4"
echo "  2. Inject uboot: make uboot-inject DISK=/dev/rdisk4"
