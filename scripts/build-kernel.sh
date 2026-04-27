#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# build-kernel.sh — Local equivalent of .github/workflows/build-kernel.yml
#
# Builds the macb-patched Talos installer-base and pushes it to GHCR as
# ghcr.io/<GHCR_ORG>/rpi-talos:<INSTALLER_TAG>
#
# Prerequisites:
#   - Docker or Podman logged in to GHCR  (docker login ghcr.io)
#   - crane installed  (brew install crane  or  go install github.com/google/go-containerregistry/cmd/crane@latest)
#   - git configured with user.name / user.email
#
# Usage:
#   ./scripts/build-kernel.sh [options]
#
# Examples:
#   ./scripts/build-kernel.sh
#   ./scripts/build-kernel.sh --talos v1.12.7 --pkg-version v1.12.0-58-g86d6af1 --tag v1.12.7-k-macb
# ------------------------------------------------------------------------------

set -euo pipefail

# pkgs Makefile uses GNU make (export define) and GNU sed (-r, Q command).
# macOS ships BSD versions — install GNU tools via brew and shadow them.
if [[ "$(uname -s)" == "Darwin" ]]; then
  if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew required on macOS. Install from https://brew.sh" >&2
    exit 1
  fi
  brew install make gnu-sed
  export PATH="$(brew --prefix make)/libexec/gnubin:$(brew --prefix gnu-sed)/libexec/gnubin:${PATH}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TALOS_VERSION="${TALOS_VERSION:-v1.12.7}"
PKG_VERSION="${PKG_VERSION:-v1.12.0-58-g86d6af1}"
INSTALLER_TAG="${INSTALLER_TAG:-${TALOS_VERSION}-k-macb}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
REGISTRY="ghcr.io"
DOCKER="${DOCKER:-docker}"
CHECKOUTS_DIR="${REPO_ROOT}/checkouts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --talos)       TALOS_VERSION="$2";  shift 2 ;;
    --pkg-version) PKG_VERSION="$2";   shift 2 ;;
    --tag)         INSTALLER_TAG="$2"; shift 2 ;;
    --org)         GHCR_ORG="$2";      shift 2 ;;
    --docker)      DOCKER="$2";        shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [options]

Options:
  --talos VERSION       Talos version to build (default: ${TALOS_VERSION})
  --pkg-version VERSION siderolabs/pkgs branch/tag (default: ${PKG_VERSION})
  --tag TAG             Output rpi-talos image tag (default: <talos>-k-macb)
  --org ORG             GHCR org/user (default: ${GHCR_ORG})
  --docker RUNTIME      docker or podman (default: ${DOCKER})

Output image: ghcr.io/<org>/rpi-talos:<tag>
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

INSTALLER_TAG="${INSTALLER_TAG:-${TALOS_VERSION}-k-macb}"

echo "============================================================"
echo " build-kernel.sh"
echo "============================================================"
echo " Talos version    : ${TALOS_VERSION}"
echo " pkgs version     : ${PKG_VERSION}"
echo " Output tag       : ${INSTALLER_TAG}"
echo " GHCR org         : ${GHCR_ORG}"
echo " Container runtime: ${DOCKER}"
echo " Checkouts dir    : ${CHECKOUTS_DIR}"
echo "============================================================"
echo ""

command -v crane >/dev/null 2>&1 || {
  echo "ERROR: crane not found."
  echo "  Install: brew install crane"
  echo "       or: go install github.com/google/go-containerregistry/cmd/crane@latest"
  exit 1
}

mkdir -p "${CHECKOUTS_DIR}"

# ── siderolabs/pkgs: standard Talos kernel + macb patches ─────────────────

echo "==> Cloning siderolabs/pkgs @ ${PKG_VERSION}..."
rm -rf "${CHECKOUTS_DIR}/pkgs"
git clone https://github.com/siderolabs/pkgs.git "${CHECKOUTS_DIR}/pkgs"
# Resolve git-describe refs (e.g. v1.12.0-58-g86d6af1 → 86d6af1)
PKGS_CHECKOUT="${PKG_VERSION}"
if [[ "${PKGS_CHECKOUT}" =~ -[0-9]+-g([0-9a-f]+)$ ]]; then
  PKGS_CHECKOUT="${BASH_REMATCH[1]}"
fi
git -C "${CHECKOUTS_DIR}/pkgs" -c advice.detachedHead=false checkout "${PKGS_CHECKOUT}"

echo ""
echo "==> Copying macb patches into pkgs..."
mkdir -p "${CHECKOUTS_DIR}/pkgs/kernel/build/patches"
cp -v "${REPO_ROOT}/patches/linux/"*.patch "${CHECKOUTS_DIR}/pkgs/kernel/build/patches/"

echo ""
echo "==> Building kernel OCI (this takes a while)..."
cd "${CHECKOUTS_DIR}/pkgs"
BUILD_CMD="docker buildx build"
[[ "$(uname -s)" == "Darwin" ]] && BUILD_CMD="podman build"
make \
  BUILD="${BUILD_CMD}" \
  REGISTRY="${REGISTRY}" \
  USERNAME="${GHCR_ORG}" \
  PUSH=true \
  PLATFORM=linux/arm64 \
  kernel

PKGS_TAG="$(git describe --tag --always --dirty --match 'v[0-9]*')"
KERNEL_IMAGE="${REGISTRY}/${GHCR_ORG}/kernel:${PKGS_TAG}"
echo ""
echo "==> Kernel OCI pushed: ${KERNEL_IMAGE}"

# ── siderolabs/talos: installer-base with macb-patched kernel ─────────────

echo ""
echo "==> Cloning siderolabs/talos @ ${TALOS_VERSION}..."
rm -rf "${CHECKOUTS_DIR}/talos"
git clone -c advice.detachedHead=false \
  --branch "${TALOS_VERSION}" \
  https://github.com/siderolabs/talos.git "${CHECKOUTS_DIR}/talos"

echo ""
echo "==> Building installer-base..."
cd "${CHECKOUTS_DIR}/talos"
make \
  TAG="${TALOS_VERSION}" \
  REGISTRY="${REGISTRY}" \
  USERNAME="${GHCR_ORG}" \
  PUSH=true \
  PKG_KERNEL="${KERNEL_IMAGE}" \
  INSTALLER_ARCH=arm64 \
  PLATFORM=linux/arm64 \
  installer-base

INSTALLER_BASE_IMAGE="${REGISTRY}/${GHCR_ORG}/installer-base:${TALOS_VERSION}"
echo ""
echo "==> installer-base pushed: ${INSTALLER_BASE_IMAGE}"

# ── Publish under stable rpi-talos name ───────────────────────────────────

RPI_TALOS_IMAGE="${REGISTRY}/${GHCR_ORG}/rpi-talos:${INSTALLER_TAG}"
echo ""
echo "==> crane copy → ${RPI_TALOS_IMAGE}..."
crane copy "${INSTALLER_BASE_IMAGE}" "${RPI_TALOS_IMAGE}"

echo ""
echo "============================================================"
echo " Done!"
echo "============================================================"
echo " kernel OCI       : ${KERNEL_IMAGE}"
echo " installer-base   : ${INSTALLER_BASE_IMAGE}"
echo " rpi-talos (use)  : ${RPI_TALOS_IMAGE}"
echo ""
echo " Update Makefile and scripts/build.sh:"
echo "   CUSTOM_INSTALLER_BASE ?= ${RPI_TALOS_IMAGE}"
echo "============================================================"
