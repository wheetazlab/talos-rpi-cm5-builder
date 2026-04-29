#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# build.sh — Build a custom Talos image for Raspberry Pi CM5
#
# Usage:
#   ./scripts/build.sh [--talos VERSION] [--overlay IMAGE] [--disk /dev/rdiskN]
#
# Examples:
#   ./scripts/build.sh
#   ./scripts/build.sh --talos v1.12.6 --overlay ghcr.io/wheetazlab/sbc-raspberrypi:pr88
#   ./scripts/build.sh --disk /dev/rdisk4   # also flashes after build
# ------------------------------------------------------------------------------

set -euo pipefail

# --- Defaults ------------------------------------------------------------------
TALOS_VERSION="${TALOS_VERSION:-v1.12.7}"
ISCSI_TOOLS_VERSION="${ISCSI_TOOLS_VERSION:-v0.2.0}"
UTIL_LINUX_VERSION="${UTIL_LINUX_VERSION:-2.41.2}"
ARCH="${ARCH:-arm64}"
DOCKER="${DOCKER:-podman}"
OVERLAY="rpi_generic"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)/_out"
DISK=""
CUSTOM_INSTALLER_BASE="${CUSTOM_INSTALLER_BASE:-ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-macb}"
CUSTOM_OVERLAY_IMAGE="${CUSTOM_OVERLAY_IMAGE:-ghcr.io/wheetazlab/sbc-raspberrypi:pr88-cd1}"
# Extra extension images appended on top of defaults (--extension adds to this)
EXTRA_EXTENSION_IMAGES=()
# Extra kernel args accumulated via --kernel-arg KEY=VALUE
EXTRA_KERNEL_ARG_FLAGS=()

# --- Arg parsing ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --talos)              TALOS_VERSION="$2";           shift 2 ;;
    --overlay)            CUSTOM_OVERLAY_IMAGE="$2";   shift 2 ;;
    --iscsi)              ISCSI_TOOLS_VERSION="$2";    shift 2 ;;
    --util-linux)         UTIL_LINUX_VERSION="$2";     shift 2 ;;
    --disk)               DISK="$2";                   shift 2 ;;
    --docker)             DOCKER="$2";                 shift 2 ;;
    --custom-installer)   CUSTOM_INSTALLER_BASE="$2";  shift 2 ;;
    --extension)          EXTRA_EXTENSION_IMAGES+=("$2"); shift 2 ;;
    --kernel-arg)         EXTRA_KERNEL_ARG_FLAGS+=("--extra-kernel-arg=$2"); shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--talos VERSION] [--overlay IMAGE] [--iscsi VERSION] [--util-linux VERSION]"
      echo "       [--disk /dev/rdiskN] [--docker podman|docker]"
      echo "       [--custom-installer IMAGE]"
      echo "       [--extension IMAGE]     (repeatable; adds extension on top of defaults)"
      echo "       [--kernel-arg KEY=VAL]  (repeatable; e.g. --kernel-arg cma=256M)"
      echo ""
      echo "Installer base override:"
      echo "  --custom-installer  ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-macb"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Image references ----------------------------------------------------------
IMAGER_IMAGE="ghcr.io/siderolabs/imager:${TALOS_VERSION}"
INSTALLER_BASE="${CUSTOM_INSTALLER_BASE:-ghcr.io/siderolabs/installer-base:${TALOS_VERSION}}"
OVERLAY_IMAGE="${CUSTOM_OVERLAY_IMAGE}"
ISCSI_TOOLS_IMAGE="ghcr.io/siderolabs/iscsi-tools:${ISCSI_TOOLS_VERSION}"
UTIL_LINUX_IMAGE="ghcr.io/siderolabs/util-linux-tools:${UTIL_LINUX_VERSION}"
RAW_IMAGE="${OUT_DIR}/metal-${ARCH}.raw"

# --- Build extension and kernel-arg arrays ------------------------------------
# If EXTENSIONS env var is set externally (e.g. from CI with digest-pinned refs),
# use it as the base. Otherwise default to iscsi-tools + util-linux-tools.
if [[ -n "${EXTENSIONS:-}" ]]; then
  read -ra _BASE_EXTS <<< "${EXTENSIONS}"
else
  _BASE_EXTS=("${ISCSI_TOOLS_IMAGE}" "${UTIL_LINUX_IMAGE}")
fi
ALL_EXTENSIONS=("${_BASE_EXTS[@]}" "${EXTRA_EXTENSION_IMAGES[@]}")
EXTENSION_ARGS=()
for ext in "${ALL_EXTENSIONS[@]}"; do
  EXTENSION_ARGS+=("--system-extension-image=${ext}")
done

# --- Summary -------------------------------------------------------------------
echo "============================================================"
echo " Talos RPI CM5 Builder"
echo "============================================================"
echo " Container runtime   : ${DOCKER}"
echo " Talos version       : ${TALOS_VERSION}"
echo " overlay image       : ${OVERLAY_IMAGE}"
echo " iscsi-tools         : ${ISCSI_TOOLS_VERSION}"
echo " util-linux-tools    : ${UTIL_LINUX_VERSION}"
echo " Extensions          : ${ALL_EXTENSIONS[*]}"
[[ ${#EXTRA_KERNEL_ARG_FLAGS[@]} -gt 0 ]] && echo " Kernel args         : ${EXTRA_KERNEL_ARG_FLAGS[*]}"
echo " Architecture        : ${ARCH}"
echo " Output directory    : ${OUT_DIR}"
echo " Target disk         : ${DISK:-<not set, skipping flash>}"
[[ -n "${CUSTOM_INSTALLER_BASE}" ]] && echo " ⚠ Custom installer  : ${CUSTOM_INSTALLER_BASE}"
echo "============================================================"
echo ""

# --- Build ---------------------------------------------------------------------
mkdir -p "${OUT_DIR}"

echo "==> Pulling imager image..."
"${DOCKER}" pull "${IMAGER_IMAGE}"

echo ""
echo "==> Building image..."
IMGARGS=(
  --base-installer-image="${INSTALLER_BASE}"
  --overlay-image="${OVERLAY_IMAGE}"
  --overlay-name="${OVERLAY}"
  "${EXTENSION_ARGS[@]}"
)
for flag in "${EXTRA_KERNEL_ARG_FLAGS[@]}"; do
  IMGARGS+=("${flag}")
done
IMGARGS+=(--arch "${ARCH}")
"${DOCKER}" run --rm -t \
  -v "${OUT_DIR}:/out" \
  -v /dev:/dev \
  --privileged \
  "${IMAGER_IMAGE}" "${OVERLAY}" \
  "${IMGARGS[@]}"

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
