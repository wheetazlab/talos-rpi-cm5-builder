#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# build.sh — Build a custom Talos image for Raspberry Pi CM5
#
# Usage:
#   ./scripts/build.sh [--talos VERSION] [--sbc VERSION] [--disk /dev/rdiskN]
#
# Examples:
#   ./scripts/build.sh
#   ./scripts/build.sh --talos v1.12.4 --sbc v0.2.0
#   ./scripts/build.sh --disk /dev/rdisk4   # also flashes after build
# ------------------------------------------------------------------------------

set -euo pipefail

# --- Defaults ------------------------------------------------------------------
TALOS_VERSION="${TALOS_VERSION:-v1.12.4}"
SBC_RPI_VERSION="${SBC_RPI_VERSION:-v0.2.0}"
ISCSI_TOOLS_VERSION="${ISCSI_TOOLS_VERSION:-v0.2.0}"
UTIL_LINUX_VERSION="${UTIL_LINUX_VERSION:-2.41.2}"
ARCH="${ARCH:-arm64}"
DOCKER="${DOCKER:-podman}"
OVERLAY="rpi_5"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/_out"
DISK=""

# --- Arg parsing ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --talos)    TALOS_VERSION="$2"; shift 2 ;;
    --sbc)      SBC_RPI_VERSION="$2"; shift 2 ;;
    --iscsi)    ISCSI_TOOLS_VERSION="$2"; shift 2 ;;
    --util-linux) UTIL_LINUX_VERSION="$2"; shift 2 ;;
    --disk)     DISK="$2";   shift 2 ;;
    --docker)   DOCKER="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--talos VERSION] [--sbc VERSION] [--iscsi VERSION] [--util-linux VERSION] [--disk /dev/rdiskN] [--docker podman|docker]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Image references ----------------------------------------------------------
IMAGER_IMAGE="ghcr.io/siderolabs/imager:${TALOS_VERSION}"
INSTALLER_BASE="ghcr.io/siderolabs/installer-base:${TALOS_VERSION}"
OVERLAY_IMAGE="ghcr.io/siderolabs/sbc-raspberrypi:${SBC_RPI_VERSION}"
ISCSI_TOOLS_IMAGE="ghcr.io/siderolabs/iscsi-tools:${ISCSI_TOOLS_VERSION}"
UTIL_LINUX_IMAGE="ghcr.io/siderolabs/util-linux-tools:${UTIL_LINUX_VERSION}"
RAW_IMAGE="${OUT_DIR}/metal-${ARCH}.raw"

# --- Summary -------------------------------------------------------------------
echo "============================================================"
echo " Talos RPI CM5 Builder"
echo "============================================================"
echo " Container runtime   : ${DOCKER}"
echo " Talos version       : ${TALOS_VERSION}"
echo " sbc-raspberrypi     : ${SBC_RPI_VERSION}"
echo " iscsi-tools         : ${ISCSI_TOOLS_VERSION}"
echo " util-linux-tools    : ${UTIL_LINUX_VERSION}"
echo " Architecture        : ${ARCH}"
echo " Output directory    : ${OUT_DIR}"
echo " Target disk         : ${DISK:-<not set, skipping flash>}"
echo "============================================================"
echo ""

# --- Build ---------------------------------------------------------------------
mkdir -p "${OUT_DIR}"

echo "==> Pulling imager image..."
"${DOCKER}" pull "${IMAGER_IMAGE}"

echo ""
echo "==> Building image..."
"${DOCKER}" run --rm -t \
  -v "${OUT_DIR}:/out" \
  -v /dev:/dev \
  --privileged \
  "${IMAGER_IMAGE}" "${OVERLAY}" \
  --base-installer-image="${INSTALLER_BASE}" \
  --overlay-image="${OVERLAY_IMAGE}" \
  --overlay-name="${OVERLAY}" \
  --system-extension-image="${ISCSI_TOOLS_IMAGE}" \
  --system-extension-image="${UTIL_LINUX_IMAGE}" \
  --arch "${ARCH}"

echo ""
echo "==> Build complete!"
ls -lh "${OUT_DIR}/"
echo ""
echo "Output image: ${RAW_IMAGE}"

# --- Optional flash ------------------------------------------------------------
if [[ -n "${DISK}" ]]; then
  if [[ ! -f "${RAW_IMAGE}" ]]; then
    echo "ERROR: ${RAW_IMAGE} not found."
    exit 1
  fi
  echo ""
  echo "==> Flashing to ${DISK} — THIS WILL ERASE THE DISK!"
  echo "    On macOS use the raw device (/dev/rdiskN) for speed."
  echo "    Press Ctrl-C within 5 seconds to abort..."
  sleep 5
  sudo dd if="${RAW_IMAGE}" of="${DISK}" bs=4m
  sudo sync
  echo ""
  echo "==> Flash complete."
fi

echo ""
echo "Next steps:"
echo "  Flash   : make flash-sd DISK=/dev/rdisk4"
echo "  Publish : ./scripts/publish.sh"
echo ""
