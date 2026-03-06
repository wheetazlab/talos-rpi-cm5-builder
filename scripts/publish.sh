#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# publish.sh — Push installer image to GHCR and create a GitHub release
#
# Prerequisites:
#   - Run `make build`      to produce _out/metal-arm64.raw
#   - Run `make installer`  to produce _out/installer-arm64.tar
#   - Already logged into GHCR via Podman Desktop
#   - gh CLI: brew install gh && gh auth login
#
# Usage:
#   ./scripts/publish.sh [--tag v1.12.4] [--org wheetazlab]
# ------------------------------------------------------------------------------

set -euo pipefail

# --- Defaults ------------------------------------------------------------------
TALOS_VERSION="${TALOS_VERSION:-v1.12.4}"
SBC_RPI_VERSION="${SBC_RPI_VERSION:-v0.2.0}"
ISCSI_TOOLS_VERSION="${ISCSI_TOOLS_VERSION:-v1.12.4}"
UTIL_LINUX_VERSION="${UTIL_LINUX_VERSION:-2.41.2}"
ARCH="${ARCH:-arm64}"
DOCKER="${DOCKER:-podman}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
GHCR_REPO="${GHCR_REPO:-talos-rpi-cm5-installer}"
GH_REPO="${GH_REPO:-wheetazlab/talos-rpi-cm5-builder}"
TAG="${TAG:-${TALOS_VERSION}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/../_out"

# --- Arg parsing ---------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)      TAG="$2";             shift 2 ;;
    --talos)    TALOS_VERSION="$2";   shift 2 ;;
    --org)      GHCR_ORG="$2";       shift 2 ;;
    --repo)     GHCR_REPO="$2";      shift 2 ;;
    --gh-repo)  GH_REPO="$2";        shift 2 ;;
    --docker)   DOCKER="$2";         shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--tag TAG] [--talos VERSION] [--org ORG] [--repo REPO] [--gh-repo OWNER/REPO] [--docker podman|docker]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

INSTALLER_TAR="${OUT_DIR}/installer-${ARCH}.tar"
# NOTE: imager outputs .raw.xz directly — no RAW_IMAGE intermediary
XZ_IMAGE="${OUT_DIR}/metal-${ARCH}.raw.xz"
GHCR_IMAGE="ghcr.io/${GHCR_ORG}/${GHCR_REPO}:${TAG}"
UPSTREAM_IMAGE="ghcr.io/siderolabs/installer-base:${TALOS_VERSION}"

# --- Pre-flight checks ---------------------------------------------------------
if [[ ! -f "${INSTALLER_TAR}" ]]; then
  echo "ERROR: ${INSTALLER_TAR} not found. Run 'make installer' first."
  exit 1
fi

if [[ ! -f "${XZ_IMAGE}" ]]; then
  echo "ERROR: ${XZ_IMAGE} not found. Run 'make build' first."
  exit 1
fi

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: gh CLI not found. Install with: brew install gh && gh auth login"
  exit 1
}

# --- Summary -------------------------------------------------------------------
echo "============================================================"
echo " Talos RPI CM5 — Publish"
echo "============================================================"
echo " Container runtime   : ${DOCKER}"
echo " Talos version       : ${TALOS_VERSION}"
echo " sbc-raspberrypi     : ${SBC_RPI_VERSION}"
echo " Installer image     : ${GHCR_IMAGE}"
echo " Release tag         : ${TAG}"
echo " GitHub repo         : ${GH_REPO}"
echo "============================================================"
echo ""

# --- Step 1: Verify compressed image (imager outputs .xz directly) ------------
echo "==> Using pre-compressed image: ${XZ_IMAGE}"
ls -lh "${XZ_IMAGE}"
echo ""

# --- Step 2: Load + tag + push installer OCI image ----------------------------
echo "==> Loading ${INSTALLER_TAR} into ${DOCKER}..."
"${DOCKER}" load -i "${INSTALLER_TAR}"

echo "==> Tagging as ${GHCR_IMAGE}..."
"${DOCKER}" tag "${UPSTREAM_IMAGE}" "${GHCR_IMAGE}"

echo "==> Pushing ${GHCR_IMAGE}..."
"${DOCKER}" push "${GHCR_IMAGE}"
echo "==> Installer image pushed!"
echo ""

# --- Step 3: Create GitHub release --------------------------------------------
echo "==> Creating GitHub release ${TAG}..."
gh release create "${TAG}" "${XZ_IMAGE}" \
  --repo "${GH_REPO}" \
  --title "Talos ${TALOS_VERSION} for Raspberry Pi CM5" \
  --notes "## Talos Linux ${TALOS_VERSION} — Custom RPI CM5 Image

Compatible with Raspberry Pi CM5 (BCM2712 C and D0/Rev 1.1 stepping).

### Included components
| Component | Version |
|-----------|---------|
| Talos Linux | \`${TALOS_VERSION}\` |
| sbc-raspberrypi overlay | \`${SBC_RPI_VERSION}\` |
| iscsi-tools | \`${ISCSI_TOOLS_VERSION}\` |
| util-linux-tools | \`${UTIL_LINUX_VERSION}\` |

### Installer image (for \`talosctl upgrade\`)
\`\`\`
${GHCR_IMAGE}
\`\`\`

### Flash (macOS)
\`\`\`bash
xzcat metal-${ARCH}.raw.xz | sudo dd of=/dev/rdiskN bs=4m
\`\`\`

### Notes
- Boot from SD card or eMMC only — NVMe boot is not yet supported
- Tested on DeskPi Super6C (CM4IO-compatible carrier)"

echo ""
echo "==> Release created: https://github.com/${GH_REPO}/releases/tag/${TAG}"
