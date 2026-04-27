#!/usr/bin/env bash
set -euo pipefail

# publish.sh mirrors .github/workflows/publish.yml
# - builds disk image + installer using custom prebuilt kernel + custom overlay
# - pushes installer tagged <talos>-k-macb (or PATCHED_RELEASE_TAG)
# - creates GitHub release with disk image

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TALOS_VERSION="${TALOS_VERSION:-v1.12.7}"
DOCKER="${DOCKER:-podman}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
GH_REPO="${GH_REPO:-${GHCR_ORG}/talos-rpi-cm5-builder}"
PATCH_SUFFIX="${PATCH_SUFFIX:-k-macb}"
PATCHED_RELEASE_TAG="${PATCHED_RELEASE_TAG:-${TALOS_VERSION}-${PATCH_SUFFIX}}"
ARCH="${ARCH:-arm64}"
CUSTOM_INSTALLER_BASE="${CUSTOM_INSTALLER_BASE:-ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-macb}"
CUSTOM_OVERLAY_IMAGE="${CUSTOM_OVERLAY_IMAGE:-ghcr.io/wheetazlab/sbc-raspberrypi:pr88}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --talos) TALOS_VERSION="$2"; shift 2 ;;
    --docker) DOCKER="$2"; shift 2 ;;
    --org) GHCR_ORG="$2"; shift 2 ;;
    --gh-repo) GH_REPO="$2"; shift 2 ;;
    --patched-release-tag) PATCHED_RELEASE_TAG="$2"; shift 2 ;;
    --patch-suffix) PATCH_SUFFIX="$2"; shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: ./scripts/publish.sh [options]

Options:
  --talos <version>             Talos version (default: ${TALOS_VERSION})
  --docker <docker|podman>      Container runtime (default: ${DOCKER})
  --org <ghcr-org>              GHCR org/user (default: ${GHCR_ORG})
  --gh-repo <owner/repo>        GitHub releases repo (default: ${GH_REPO})
  --patch-suffix <suffix>       Suffix for patched line (default: ${PATCH_SUFFIX})
  --patched-release-tag <tag>   Override release tag (default: ${PATCHED_RELEASE_TAG})
  --custom-installer <image>    Base installer image (default: ${CUSTOM_INSTALLER_BASE})
EOF
      exit 0
      ;;
    --custom-installer) CUSTOM_INSTALLER_BASE="$2"; shift 2 ;;
    --overlay-image) CUSTOM_OVERLAY_IMAGE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${PATCHED_RELEASE_TAG}" == "${TALOS_VERSION}-${PATCH_SUFFIX}" ]]; then
  PATCHED_RELEASE_TAG="${TALOS_VERSION}-${PATCH_SUFFIX}"
fi

VER="${TALOS_VERSION#v}"
OUT_DIR="${REPO_ROOT}/_out"
DISK_IMAGE="${OUT_DIR}/metal-${ARCH}.raw.xz"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: gh CLI not found. Install and authenticate first."
  exit 1
}

echo "==> Patched publish"
echo "    talos_version      : ${TALOS_VERSION}"
echo "    imager             : ghcr.io/siderolabs/imager:${TALOS_VERSION}"
echo "    installer_base     : ${CUSTOM_INSTALLER_BASE}"
echo "    overlay_image      : ${CUSTOM_OVERLAY_IMAGE}"
echo "    patched_release    : ${PATCHED_RELEASE_TAG}"
echo "    gh_repo            : ${GH_REPO}"

rm -f "${DISK_IMAGE}"

pushd "${REPO_ROOT}" >/dev/null

echo "==> Building image"
make build DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CUSTOM_INSTALLER_BASE="${CUSTOM_INSTALLER_BASE}" CUSTOM_OVERLAY_IMAGE="${CUSTOM_OVERLAY_IMAGE}"
make installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CUSTOM_INSTALLER_BASE="${CUSTOM_INSTALLER_BASE}" CUSTOM_OVERLAY_IMAGE="${CUSTOM_OVERLAY_IMAGE}"
make push-installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" INSTALLER_TAG="${PATCHED_RELEASE_TAG}" CUSTOM_INSTALLER_BASE="${CUSTOM_INSTALLER_BASE}"

ISCSI_VERSION="$(grep '^ISCSI_TOOLS_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
UTIL_VERSION="$(grep '^UTIL_LINUX_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"

NOTES=$(cat <<EOF
> ⚠️ Experimental build, use at your own risk.

This is a patched Talos build for **Raspberry Pi CM4 and CM5** boards.
Uses the \`rpi_generic\` overlay (PR #88) which supports CM4IO/CM5IO carriers and Pi 5.

### Components

| Component | Version / Image |
|-----------|------------------|
| Imager | \`ghcr.io/siderolabs/imager:${TALOS_VERSION}\` |
| Installer base | \`${CUSTOM_INSTALLER_BASE}\` (standard Talos kernel + 3 macb patches) |
| Talos | \`${TALOS_VERSION}\` |
| SBC overlay | \`${CUSTOM_OVERLAY_IMAGE}\` (PR #88 — BCM2712/RP1 U-Boot + NVMe, rpi_generic) |
| iscsi-tools | \`ghcr.io/siderolabs/iscsi-tools:${ISCSI_VERSION}\` |
| util-linux-tools | \`ghcr.io/siderolabs/util-linux-tools:${UTIL_VERSION}\` |

### Supported boards

- Raspberry Pi CM5 (CM5IO, CM4IO-compatible carriers e.g. DeskPi Super6C)
- Raspberry Pi CM4 (CM4IO and compatible carriers)
- Raspberry Pi 5

### What's available

- 📦 **\`metal-arm64.raw.xz\`** — disk image for CM4/CM5/Pi5
- ⚙️  **Installer:** \`ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}\`

### Install

- **Fresh install**
  - Download \`metal-arm64.raw.xz\` from this release
  - Flash with \`dd\` or your favorite tool

- **Upgrade existing node**
  \`\`\`bash
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}
  \`\`\`
EOF
)

PRERELEASE_FLAG=""
if [[ "${TALOS_VERSION}" =~ -(alpha|beta|rc)\. ]]; then
  PRERELEASE_FLAG="--prerelease"
fi

gh release delete "${PATCHED_RELEASE_TAG}" --repo "${GH_REPO}" --yes 2>/dev/null || true
gh release create \
  "${PATCHED_RELEASE_TAG}" \
  "${DISK_IMAGE}" \
  --repo "${GH_REPO}" \
  --title "${PATCHED_RELEASE_TAG}" \
  ${PRERELEASE_FLAG} \
  --notes "${NOTES}"

popd >/dev/null

echo "==> Done: https://github.com/${GH_REPO}/releases/tag/${PATCHED_RELEASE_TAG}"
