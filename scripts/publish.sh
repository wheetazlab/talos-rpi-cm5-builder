#!/usr/bin/env bash
set -euo pipefail

# publish.sh (patched flow) mirrors .github/workflows/publish.yml
# - builds both variants (lite, emmc)
# - uses patched imager
# - pushes installers tagged <talos>-macb-fix-<variant>
# - creates release tag <talos>-macb-fix with two disk images

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TALOS_VERSION="${TALOS_VERSION:-v1.12.4}"
DOCKER="${DOCKER:-podman}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
GH_REPO="${GH_REPO:-${GHCR_ORG}/talos-rpi-cm5-builder}"
PATCH_SUFFIX="${PATCH_SUFFIX:-macb-fix}"
PATCHED_RELEASE_TAG="${PATCHED_RELEASE_TAG:-${TALOS_VERSION}-${PATCH_SUFFIX}}"
ARCH="${ARCH:-arm64}"

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
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ "${PATCHED_RELEASE_TAG}" == "${TALOS_VERSION}-${PATCH_SUFFIX}" ]]; then
  PATCHED_RELEASE_TAG="${TALOS_VERSION}-${PATCH_SUFFIX}"
fi

VER="${TALOS_VERSION#v}"
CUSTOM_IMAGER="ghcr.io/${GHCR_ORG}/talos-rpi-cm5-builder/imager:${VER}-${PATCH_SUFFIX}"
OUT_DIR="${REPO_ROOT}/_out"
LITE_XZ="${OUT_DIR}/metal-${ARCH}-lite.raw.xz"
EMMC_XZ="${OUT_DIR}/metal-${ARCH}-emmc.raw.xz"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: gh CLI not found. Install and authenticate first."
  exit 1
}

echo "==> Patched publish"
echo "    talos_version      : ${TALOS_VERSION}"
echo "    patched_imager     : ${CUSTOM_IMAGER}"
echo "    patched_release    : ${PATCHED_RELEASE_TAG}"
echo "    gh_repo            : ${GH_REPO}"

rm -f "${LITE_XZ}" "${EMMC_XZ}"

pushd "${REPO_ROOT}" >/dev/null

make uboot-build DOCKER="${DOCKER}"

for variant in lite emmc; do
  echo "==> Building variant: ${variant}"
  make build DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CM5_VARIANT="${variant}" CUSTOM_IMAGER="${CUSTOM_IMAGER}"
  make uboot-inject
  make installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CM5_VARIANT="${variant}" CUSTOM_IMAGER="${CUSTOM_IMAGER}"
  make push-installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" INSTALLER_TAG="${PATCHED_RELEASE_TAG}-${variant}"
  mv "${OUT_DIR}/metal-${ARCH}.raw.xz" "${OUT_DIR}/metal-${ARCH}-${variant}.raw.xz"
done

ISCSI_VERSION="$(grep '^ISCSI_TOOLS_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
UTIL_VERSION="$(grep '^UTIL_LINUX_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
SBC_VERSION="$(grep '^SBC_RPI_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
UBOOT_VER="$(grep '^UBOOT_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
PKGS_REF="$(grep '^PKGS_REF' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
LINUX_KERNEL_VERSION="$(grep '^LINUX_KERNEL_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
VER="${TALOS_VERSION#v}"
PATCHED_IMAGER_TAG="ghcr.io/${GHCR_ORG}/talos-rpi-cm5-builder/imager:${VER}-${PATCH_SUFFIX}"
EXTENSIONS="ghcr.io/siderolabs/iscsi-tools:${ISCSI_VERSION} ghcr.io/siderolabs/util-linux-tools:${UTIL_VERSION}"

NOTES=$(cat <<EOF
> ⚠️ Experimental build, use at your own risk.

This is a patched Talos build for the Raspberry Pi CM5.

### Components

| Component | Version / Image |
|-----------|------------------|
| Imager | \`${PATCHED_IMAGER_TAG}\` |
| Installer base | \`ghcr.io/siderolabs/installer-base:${TALOS_VERSION}\` |
| Talos | \`${TALOS_VERSION}\` |
| Kernel | Linux ${LINUX_KERNEL_VERSION} — \`siderolabs/pkgs@${PKGS_REF}\` — patched: macb RP1 PCIe TSTART flush |
| U-Boot | \`${UBOOT_VER}\` — patched: BCM2712 NVMe/PCIe |
| SBC overlay | \`ghcr.io/siderolabs/sbc-raspberrypi:${SBC_VERSION}\` |
| iscsi-tools | \`ghcr.io/siderolabs/iscsi-tools:${ISCSI_VERSION}\` |
| util-linux-tools | \`ghcr.io/siderolabs/util-linux-tools:${UTIL_VERSION}\` |

### config.txt overlay options

- \`dtparam=i2c_arm=on\` _(always included by default)_

### Extra kernel args

| Variant | Kernel args |
|---------|-------------|
| \`lite\` (CM5 Lite — no onboard eMMC) | \`module_blacklist=sdhci_brcmstb\` |
| \`emmc\` (CM5 with onboard eMMC) | _(none — defaults only)_ |

### What's available

- 📦 **\`metal-arm64-lite.raw.xz\`** — CM5 Lite (no onboard eMMC)
- 📦 **\`metal-arm64-emmc.raw.xz\`** — CM5 with onboard eMMC
- ⚙️  **Installer — CM5 Lite:** \`ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}-lite\`
- ⚙️  **Installer — CM5 eMMC:** \`ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}-emmc\`

### Install

- **Fresh install**
  - Download the raw disk image for your CM5 variant from this release
  - Flash with \`dd\` or your favorite tool

- **Upgrade existing node**
  \`\`\`bash
  # CM5 Lite
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}-lite
  # CM5 with eMMC
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${PATCHED_RELEASE_TAG}-emmc
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
  "${LITE_XZ}" \
  "${EMMC_XZ}" \
  --repo "${GH_REPO}" \
  --title "${PATCHED_RELEASE_TAG}" \
  ${PRERELEASE_FLAG} \
  --notes "${NOTES}"

popd >/dev/null

echo "==> Done: https://github.com/${GH_REPO}/releases/tag/${PATCHED_RELEASE_TAG}"
