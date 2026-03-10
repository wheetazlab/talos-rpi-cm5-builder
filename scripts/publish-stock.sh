#!/usr/bin/env bash
set -euo pipefail

# publish-stock.sh mirrors .github/workflows/publish-stock.yml
# - builds both variants (lite, emmc)
# - uses stock imager/kernel
# - pushes installers tagged <talos>-<variant>
# - creates release tag <talos> with two disk images

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TALOS_VERSION="${TALOS_VERSION:-v1.12.4}"
DOCKER="${DOCKER:-podman}"
GHCR_ORG="${GHCR_ORG:-wheetazlab}"
GH_REPO="${GH_REPO:-${GHCR_ORG}/talos-rpi-cm5-builder}"
ARCH="${ARCH:-arm64}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --talos) TALOS_VERSION="$2"; shift 2 ;;
    --docker) DOCKER="$2"; shift 2 ;;
    --org) GHCR_ORG="$2"; shift 2 ;;
    --gh-repo) GH_REPO="$2"; shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: ./scripts/publish-stock.sh [options]

Options:
  --talos <version>          Talos version (default: ${TALOS_VERSION})
  --docker <docker|podman>   Container runtime (default: ${DOCKER})
  --org <ghcr-org>           GHCR org/user (default: ${GHCR_ORG})
  --gh-repo <owner/repo>     GitHub releases repo (default: ${GH_REPO})
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

OUT_DIR="${REPO_ROOT}/_out"
LITE_XZ="${OUT_DIR}/metal-${ARCH}-lite.raw.xz"
EMMC_XZ="${OUT_DIR}/metal-${ARCH}-emmc.raw.xz"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: gh CLI not found. Install and authenticate first."
  exit 1
}

echo "==> Stock publish"
echo "    talos_version      : ${TALOS_VERSION}"
echo "    release            : ${TALOS_VERSION}"
echo "    gh_repo            : ${GH_REPO}"

rm -f "${LITE_XZ}" "${EMMC_XZ}"

pushd "${REPO_ROOT}" >/dev/null

make uboot-build DOCKER="${DOCKER}"

for variant in lite emmc; do
  echo "==> Building variant: ${variant}"
  make build DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CM5_VARIANT="${variant}"
  make uboot-inject
  make installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" CM5_VARIANT="${variant}"
  make push-installer DOCKER="${DOCKER}" TALOS_VERSION="${TALOS_VERSION}" INSTALLER_TAG="${TALOS_VERSION}-${variant}"
  mv "${OUT_DIR}/metal-${ARCH}.raw.xz" "${OUT_DIR}/metal-${ARCH}-${variant}.raw.xz"
done

ISCSI_VERSION="$(grep '^ISCSI_TOOLS_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
UTIL_VERSION="$(grep '^UTIL_LINUX_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
SBC_VERSION="$(grep '^SBC_RPI_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
UBOOT_VER="$(grep '^UBOOT_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
PKGS_REF="$(grep '^PKGS_REF' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"
LINUX_KERNEL_VERSION="$(grep '^LINUX_KERNEL_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"

NOTES=$(cat <<EOF
> ⚠️ Experimental build, use at your own risk.

This is a Talos build for the Raspberry Pi CM5.

### Components

| Component | Version / Image |
|-----------|------------------|
| Imager | \`ghcr.io/siderolabs/imager:${TALOS_VERSION}\` |
| Installer base | \`ghcr.io/siderolabs/installer-base:${TALOS_VERSION}\` |
| Talos | \`${TALOS_VERSION}\` |
| Kernel | Linux ${LINUX_KERNEL_VERSION} — \`siderolabs/pkgs@${PKGS_REF}\` — stock |
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
- ⚙️  **Installer — CM5 Lite:** \`ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${TALOS_VERSION}-lite\`
- ⚙️  **Installer — CM5 eMMC:** \`ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${TALOS_VERSION}-emmc\`

### Install

- **Fresh install**
  - Download the raw disk image for your CM5 variant from this release
  - Flash with \`dd\` or your favorite tool

- **Upgrade existing node**
  \`\`\`bash
  # CM5 Lite
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${TALOS_VERSION}-lite
  # CM5 with eMMC
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-cm5-installer:${TALOS_VERSION}-emmc
  \`\`\`
EOF
)

PRERELEASE_FLAG=""
if [[ "${TALOS_VERSION}" =~ -(alpha|beta|rc)\. ]]; then
  PRERELEASE_FLAG="--prerelease"
fi

gh release delete "${TALOS_VERSION}" --repo "${GH_REPO}" --yes 2>/dev/null || true
gh release create \
  "${TALOS_VERSION}" \
  "${LITE_XZ}" \
  "${EMMC_XZ}" \
  --repo "${GH_REPO}" \
  --title "${TALOS_VERSION}" \
  ${PRERELEASE_FLAG} \
  --notes "${NOTES}"

popd >/dev/null

echo "==> Done: https://github.com/${GH_REPO}/releases/tag/${TALOS_VERSION}"
