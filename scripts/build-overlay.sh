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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)     PR88_SHA="$2";    shift 2 ;;
    --tag)     OVERLAY_TAG="$2"; shift 2 ;;
    --org)     GHCR_ORG="$2";   shift 2 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [options]

Options:
  --sha SHA   sbc-raspberrypi commit to checkout (default: ${PR88_SHA})
  --tag TAG   Output overlay image tag (default: ${OVERLAY_TAG})
  --org ORG   GHCR org/user (default: ${GHCR_ORG})

Output image: ghcr.io/<org>/sbc-raspberrypi:<tag>
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "============================================================"
echo " build-overlay.sh"
echo "============================================================"
echo " PR #88 SHA       : ${PR88_SHA}"
echo " Overlay tag      : ${OVERLAY_TAG}"
echo " GHCR org         : ${GHCR_ORG}"
echo " Checkouts dir    : ${CHECKOUTS_DIR}"
echo "============================================================"
echo ""

mkdir -p "${CHECKOUTS_DIR}"

# ── Clone sbc-raspberrypi and checkout the specific PR commit ─────────────

echo "==> Cloning sidero-community/sbc-raspberrypi..."
rm -rf "${CHECKOUTS_DIR}/sbc-raspberrypi"
git clone https://github.com/sidero-community/sbc-raspberrypi.git \
  "${CHECKOUTS_DIR}/sbc-raspberrypi"

echo ""
echo "==> Checking out commit ${PR88_SHA}..."
cd "${CHECKOUTS_DIR}/sbc-raspberrypi"
git -c advice.detachedHead=false checkout "${PR88_SHA}"

# ── Build and push the overlay OCI ───────────────────────────────────────

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
