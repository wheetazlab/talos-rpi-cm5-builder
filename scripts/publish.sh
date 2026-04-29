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
GH_REPO="${GH_REPO:-${GHCR_ORG}/talos-rpi-builder}"
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
LINUX_KERNEL_VERSION="$(grep '^LINUX_KERNEL_VERSION' Makefile | awk -F'?=' '{print $2}' | tr -d ' ')"

NOTES_FILE="$(mktemp -t talos-rpi-notes.XXXXXX)"
trap 'rm -f "${NOTES_FILE}"' EXIT

cat > "${NOTES_FILE}" <<EOF
> ⚠️ Experimental build — use at your own risk.

Patched Talos build for **Raspberry Pi CM4, CM5, Pi 4, and Pi 5** boards.

A **single unified \`metal-arm64.raw.xz\`** that boots on CM4, CM5, Pi 4, *and* Pi 5 — same kernel, same initramfs, same DTB set, no per-board variants. This is made possible by [@appkins](https://github.com/appkins)'s [siderolabs/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88), which collapses BCM2711 (CM4/Pi 4) and BCM2712 (CM5/Pi 5) support into one \`rpi_generic\` installer.

Combines four independent layers on top of upstream Talos ${TALOS_VERSION}:

1. **Custom Linux kernel** (\`${LINUX_KERNEL_VERSION}\`) — standard \`siderolabs/pkgs\` mainline kernel rebuilt with three \`net: macb\` patches targeting the BCM2712 PCIe Ethernet controller (patches by [@lukaszraczylo](https://github.com/lukaszraczylo), merged into \`siderolabs/pkgs\` as [PR #1526](https://github.com/siderolabs/pkgs/pull/1526) at commit [\`9a718f6\`](https://github.com/siderolabs/pkgs/commit/9a718f6a64aaeb260a9e5182c93817676beff270); addresses [sbc-raspberrypi#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82) / [sbc-raspberrypi#91](https://github.com/siderolabs/sbc-raspberrypi/issues/91) / [cilium#43198](https://github.com/cilium/cilium/issues/43198)):
   - \`net: macb: flush PCIe posted write after TSTART doorbell\` — prevents TX hangs caused by posted-write reordering across the PCIe bridge.
   - \`net: macb: re-check ISR after IER re-enable in macb_tx_poll\` — closes a race window where a TX interrupt fires between ISR read and IER re-enable, masking the event.
   - \`net: macb: add TX stall watchdog\` — defence-in-depth safety net that kicks the TX path if all three patches fail to prevent a stall in a given edge case.
2. **\`rpi_generic\` SBC overlay** (\`${CUSTOM_OVERLAY_IMAGE}\`, [siderolabs/sbc-raspberrypi PR #88](https://github.com/siderolabs/sbc-raspberrypi/pull/88) by [@appkins](https://github.com/appkins)) — U-Boot + RP1/BCM2712 device-tree support enabling NVMe boot, CM4IO/CM5IO carrier boards, and Pi 5 single-board form factor.
3. **CM5 SD card-detect DTB patch** — drops \`broken-cd;\` from the \`&sdio1\` node in \`bcm2712-rpi-cm5.dtsi\` (injected at overlay build time as \`0011-cm5-sdio1-drop-broken-cd.patch\`). Upstream \`broken-cd;\` forces \`MMC_CAP_NEEDS_POLL\`, which prevents \`mmc_rescan()\` from short-circuiting on an empty microSD slot and produces a perpetual \`mmc0: Timeout waiting for hardware cmd interrupt\` log loop on NVMe-only boots. The BCM2712 SDHCI controller's native \`SDHCI_CARD_PRESENT\` bit and \`CARD_INSERT/REMOVE\` interrupts handle empty-slot quiet and hot-insert correctly without \`broken-cd\`. Verified on CM4IO, CM5IO, and DeskPi Super6C.
4. **Extensions** — \`iscsi-tools\` (iSCSI initiator for Longhorn/OpenEBS) and \`util-linux-tools\` (loopback/filesystem utilities) baked in at digest-pinned versions.

### Components

| Component | Version / Image |
|-----------|------------------|
| Talos | \`${TALOS_VERSION}\` |
| Imager | \`ghcr.io/siderolabs/imager:${TALOS_VERSION}\` |
| Installer base | \`${CUSTOM_INSTALLER_BASE}\` |
| Kernel | Linux ${LINUX_KERNEL_VERSION} (3× macb PCIe patches) |
| SBC overlay | \`${CUSTOM_OVERLAY_IMAGE}\` (rpi_generic — PR #88 + CM5 sdio1 broken-cd drop) |
| iscsi-tools | \`ghcr.io/siderolabs/iscsi-tools:${ISCSI_VERSION}\` |
| util-linux-tools | \`ghcr.io/siderolabs/util-linux-tools:${UTIL_VERSION}\` |

### Supported boards

- Raspberry Pi CM5 (CM5IO, CM4IO-compatible carriers e.g. DeskPi Super6C)
- Raspberry Pi CM4 (CM4IO and compatible carriers)
- Raspberry Pi 5
- Raspberry Pi 4 Model B

### What's available

- 📦 **\`metal-arm64.raw.xz\`** — disk image for CM4/CM5/Pi 4/Pi 5
- ⚙️  **Installer:** \`ghcr.io/${GHCR_ORG}/talos-rpi-installer:${PATCHED_RELEASE_TAG}\`

### Install

- **Fresh install**
  - Download \`metal-arm64.raw.xz\` from this release
  - Flash with \`dd\` or your favorite tool

- **Upgrade existing node**
  \`\`\`bash
  talosctl upgrade --nodes <NODE_IP> --image ghcr.io/${GHCR_ORG}/talos-rpi-installer:${PATCHED_RELEASE_TAG}
  \`\`\`
EOF

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
  --notes-file "${NOTES_FILE}"

popd >/dev/null

echo "==> Done: https://github.com/${GH_REPO}/releases/tag/${PATCHED_RELEASE_TAG}"
