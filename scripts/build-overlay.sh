#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# build-overlay.sh — Local equivalent of .github/workflows/build-overlay.yml
#
# Builds the sbc-raspberrypi Talos overlay (PR #88) and pushes it to GHCR as
# ghcr.io/<GHCR_ORG>/sbc-raspberrypi:<OVERLAY_TAG>
#
# The PR #88 commit adds CM5 + Raspberry Pi 5 board support that has not yet
# merged to the sbc-raspberrypi main branch.
#
# Prerequisites:
#   - Docker or Podman logged in to GHCR  (docker login ghcr.io)
#   - git configured with user.name / user.email
#
# Usage:
#   ./scripts/build-overlay.sh [options]
#
# Examples:
#   ./scripts/build-overlay.sh
#   ./scripts/build-overlay.sh --org myorg --tag pr88
# ------------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# PR #88 commit: CM5 + Pi5 overlay support
PR88_SHA="${PR88_SHA:-e5ab77462b5ed1ee594ae71f35c0262b51a72524}"
OVERLAY_TAG="${OVERLAY_TAG:-pr88}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
REGISTRY="ghcr.io"
CHECKOUTS_DIR="${REPO_ROOT}/checkouts"

# Optional overrides for overlay internals (does not change Talos kernel).
# UBOOT_* map to upstream u-boot source tarball checksums:
#   https://ftp.denx.de/pub/u-boot/u-boot-<version>.tar.bz2
# These are NOT checksums for prebuilt SD/NVMe images.
UBOOT_VERSION="${UBOOT_VERSION:-2026.01}"
UBOOT_SHA256="${UBOOT_SHA256:-b60d5865cefdbc75da8da4156c56c458e00de75a49b80c1a2e58a96e30ad0d54}"
UBOOT_SHA512="${UBOOT_SHA512:-b1f988a497c77da60faf89ed33034e9ae58c4cd7f208e5ce451f1372e13540a66289bee4f08ca2f68f105d73f1ceae058b1f713db549edbcc885d9c66bdc4f8b}"
RPI_DTB_REF="${RPI_DTB_REF:-stable_20250428}"
RPI_DTB_SHA256="${RPI_DTB_SHA256:-c95906cfbc7808de5860c6d86537bea22e3501f600a5209de59a86cb436886f6}"
RPI_DTB_SHA512="${RPI_DTB_SHA512:-0ed5d490c491e590b5980dccf6fcac0dd3c47accbfacd40d91507c12801cff34fa6a1c68991c8a6c57bb259c909121414766f35a0b11c4bd5d62c3e11d710839}"
PI5_SD_POLL_ONCE="${PI5_SD_POLL_ONCE:-true}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha) PR88_SHA="$2"; shift 2 ;;
    --tag) OVERLAY_TAG="$2"; shift 2 ;;
    --org) GHCR_ORG="$2"; shift 2 ;;
    --uboot-version) UBOOT_VERSION="$2"; shift 2 ;;
    --uboot-sha256) UBOOT_SHA256="$2"; shift 2 ;;
    --uboot-sha512) UBOOT_SHA512="$2"; shift 2 ;;
    --rpi-dtb-ref) RPI_DTB_REF="$2"; shift 2 ;;
    --rpi-dtb-sha256) RPI_DTB_SHA256="$2"; shift 2 ;;
    --rpi-dtb-sha512) RPI_DTB_SHA512="$2"; shift 2 ;;
    --pi5-sd-poll-once) PI5_SD_POLL_ONCE="$2"; shift 2 ;;
    --help|-h)
      cat <<USAGE
Usage: $0 [options]

Options:
  --sha SHA            sbc-raspberrypi commit to checkout (default: ${PR88_SHA})
  --tag TAG            Output overlay image tag (default: ${OVERLAY_TAG})
  --org ORG            GHCR org/user (default: ${GHCR_ORG})
  --uboot-version VER  u-boot/u-boot version (default: ${UBOOT_VERSION})
  --uboot-sha256 SUM   sha256 for u-boot-<ver>.tar.bz2 (default: ${UBOOT_SHA256})
  --uboot-sha512 SUM   sha512 for u-boot-<ver>.tar.bz2 (default: ${UBOOT_SHA512})
  --rpi-dtb-ref REF    raspberrypi/linux ref for DTB packaging (default: ${RPI_DTB_REF})
  --rpi-dtb-sha256 SUM DTB source tarball sha256 (default: ${RPI_DTB_SHA256})
  --rpi-dtb-sha512 SUM DTB source tarball sha512 (default: ${RPI_DTB_SHA512})
  --pi5-sd-poll-once B Enable dtparam=sd_poll_once for [pi5] (default: ${PI5_SD_POLL_ONCE})

Output image: ghcr.io/<org>/sbc-raspberrypi:<tag>
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "============================================================"
echo " build-overlay.sh"
echo "============================================================"
echo " PR #88 SHA       : ${PR88_SHA}"
echo " Overlay tag      : ${OVERLAY_TAG}"
echo " GHCR org         : ${GHCR_ORG}"
echo " U-Boot version   : ${UBOOT_VERSION}"
echo " DTB ref          : ${RPI_DTB_REF}"
echo " Pi5 sd_poll_once : ${PI5_SD_POLL_ONCE}"
echo " Checkouts dir    : ${CHECKOUTS_DIR}"
echo "============================================================"
echo ""

mkdir -p "${CHECKOUTS_DIR}"

# -- Clone sbc-raspberrypi and checkout the specific PR commit --------------

echo "==> Cloning sidero-community/sbc-raspberrypi..."
rm -rf "${CHECKOUTS_DIR}/sbc-raspberrypi"
git clone https://github.com/sidero-community/sbc-raspberrypi.git \
  "${CHECKOUTS_DIR}/sbc-raspberrypi"

echo ""
echo "==> Checking out commit ${PR88_SHA}..."
cd "${CHECKOUTS_DIR}/sbc-raspberrypi"
git -c advice.detachedHead=false checkout "${PR88_SHA}"

# Keep Talos kernel untouched; only tune overlay internals.
echo ""
echo "==> Patching overlay Pkgfile/DTB source pins..."
perl -i -pe "s|^(\s*uboot_version:\s*).*$|\$1${UBOOT_VERSION}|" Pkgfile
perl -i -pe "s|^(\s*uboot_sha256:\s*).*$|\$1${UBOOT_SHA256}|" Pkgfile
perl -i -pe "s|^(\s*uboot_sha512:\s*).*$|\$1${UBOOT_SHA512}|" Pkgfile
perl -i -pe "s|^(\s*raspberrypi_kernel_version:\s*).*$|\$1${RPI_DTB_REF}|" Pkgfile
perl -i -pe "s|^(\s*raspberrypi_kernel_sha256:\s*).*$|\$1${RPI_DTB_SHA256}|" Pkgfile
perl -i -pe "s|^(\s*raspberrypi_kernel_sha512:\s*).*$|\$1${RPI_DTB_SHA512}|" Pkgfile
perl -i -pe "s|https://github.com/raspberrypi/linux/archive/refs/tags/\{\{ \.raspberrypi_kernel_version \}\}\.tar\.gz|https://github.com/raspberrypi/linux/archive/\{\{ .raspberrypi_kernel_version \}\}\.tar\.gz|g" artifacts/dtb/raspberrypi/pkg.yaml

if [[ "${PI5_SD_POLL_ONCE}" == "true" ]]; then
  if ! grep -q '^dtparam=sd_poll_once' installers/rpi_generic/src/config.txt; then
    awk '
      { print }
      /^\[pi5\]$/ { print "dtparam=sd_poll_once" }
    ' installers/rpi_generic/src/config.txt > installers/rpi_generic/src/config.txt.new
    mv installers/rpi_generic/src/config.txt.new installers/rpi_generic/src/config.txt
  fi
fi

# -- Build and push the overlay OCI ------------------------------------------

echo ""
echo "==> Building sbc-raspberrypi overlay (this takes a while)..."
make \
  sbc-raspberrypi \
  REGISTRY="${REGISTRY}" \
  USERNAME="${GHCR_ORG}" \
  TAG="${OVERLAY_TAG}" \
  PLATFORM=linux/arm64 \
  PUSH=true

OVERLAY_IMAGE="${REGISTRY}/${GHCR_ORG}/sbc-raspberrypi:${OVERLAY_TAG}"

echo ""
echo "============================================================"
echo " Done!"
echo "============================================================"
echo " Overlay image    : ${OVERLAY_IMAGE}"
echo ""
echo " Update Makefile and scripts/build.sh:"
echo "   CUSTOM_OVERLAY_IMAGE ?= ${OVERLAY_IMAGE}"
echo "============================================================"
