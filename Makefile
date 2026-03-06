# ------------------------------------------------------------------------------
# Talos Linux — Custom Image Builder for Raspberry Pi CM5
# Board: DeskPi Super6C (CM4IO-compatible carrier)
# ------------------------------------------------------------------------------

# --- Versions ------------------------------------------------------------------
TALOS_VERSION        ?= v1.12.4
SBC_RPI_VERSION      ?= v0.2.0
ISCSI_TOOLS_VERSION  ?= v0.2.0
UTIL_LINUX_VERSION   ?= 2.41.2

# --- Build config --------------------------------------------------------------
ARCH     ?= arm64
OUT_DIR  ?= _out
OVERLAY  := rpi_5
DOCKER   ?= podman

# --- GHCR publish config -------------------------------------------------------
GHCR_ORG        ?= wheetazlab
GHCR_REPO       ?= talos-rpi-cm5-installer
GHCR_IMAGE      := ghcr.io/$(GHCR_ORG)/$(GHCR_REPO):$(TALOS_VERSION)

# --- Release config ------------------------------------------------------------
# TAG is used for `make release` — override if you want a custom tag.
# e.g. make release TAG=v1.12.4-1
TAG             ?= $(TALOS_VERSION)
GH_REPO         ?= $(GHCR_ORG)/talos-rpi-cm5-builder

# --- Image refs ----------------------------------------------------------------
IMAGER_IMAGE        := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
INSTALLER_BASE      := ghcr.io/siderolabs/installer-base:$(TALOS_VERSION)
OVERLAY_IMAGE       := ghcr.io/siderolabs/sbc-raspberrypi:$(SBC_RPI_VERSION)
ISCSI_TOOLS_IMAGE   := ghcr.io/siderolabs/iscsi-tools:$(ISCSI_TOOLS_VERSION)
UTIL_LINUX_IMAGE    := ghcr.io/siderolabs/util-linux-tools:$(UTIL_LINUX_VERSION)

# --- Output files --------------------------------------------------------------
# NOTE: The Talos imager outputs .raw.xz directly — no separate compress step needed
XZ_IMAGE          := $(OUT_DIR)/metal-$(ARCH).raw.xz
INSTALLER_TAR     := $(OUT_DIR)/installer-$(ARCH).tar

# -------------------------------------------------------------------------------

.PHONY: all build compress flash-sd installer push-installer release publish pull-images clean help

all: build

## build: Build the custom Talos disk image for RPI CM5
build: $(OUT_DIR)
	@echo "==> Building Talos $(TALOS_VERSION) image for RPI CM5 (sbc-raspberrypi $(SBC_RPI_VERSION))"
	$(DOCKER) run --rm -t \
		-v $(CURDIR)/$(OUT_DIR):/out \
		-v /dev:/dev \
		--privileged \
		$(IMAGER_IMAGE) $(OVERLAY) \
		--base-installer-image="$(INSTALLER_BASE)" \
		--overlay-image="$(OVERLAY_IMAGE)" \
		--overlay-name="$(OVERLAY)" \
		--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
		--system-extension-image="$(UTIL_LINUX_IMAGE)" \
		--arch $(ARCH)
	@echo ""
	@echo "==> Build complete!"
	@ls -lh $(OUT_DIR)/
	@echo ""
	@echo "Image: $(XZ_IMAGE)"

## installer: Build the Talos installer OCI image (used for talosctl upgrade)
installer: $(OUT_DIR)
	@echo "==> Building Talos installer image for RPI CM5"
	$(DOCKER) run --rm -t \
		-v $(CURDIR)/$(OUT_DIR):/out \
		-v /dev:/dev \
		--privileged \
		$(IMAGER_IMAGE) installer \
		--base-installer-image="$(INSTALLER_BASE)" \
		--overlay-image="$(OVERLAY_IMAGE)" \
		--overlay-name="$(OVERLAY)" \
		--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
		--system-extension-image="$(UTIL_LINUX_IMAGE)" \
		--arch $(ARCH)
	@echo "==> Installer image saved to $(INSTALLER_TAR)"

## compress: No-op — imager already outputs .raw.xz directly
compress:
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> $(XZ_IMAGE) already compressed (imager outputs .xz directly):" && ls -lh $(XZ_IMAGE)

## push-installer: Load installer OCI tar and push to ghcr.io/$(GHCR_ORG)
push-installer:
	@test -f "$(INSTALLER_TAR)" || (echo "ERROR: $(INSTALLER_TAR) not found. Run 'make installer' first." && exit 1)
	@echo "==> Loading $(INSTALLER_TAR) into $(DOCKER)..."
	$(DOCKER) load -i $(INSTALLER_TAR)
	@echo "==> Tagging as $(GHCR_IMAGE)"
	$(DOCKER) tag ghcr.io/siderolabs/installer:$(TALOS_VERSION) $(GHCR_IMAGE)
	@echo "==> Pushing $(GHCR_IMAGE)"
	$(DOCKER) push $(GHCR_IMAGE)
	@echo "==> Push complete!"

## release: Create a GitHub release and upload the .raw.xz image (requires gh CLI)
release:
	@command -v gh >/dev/null 2>&1 || (echo "ERROR: 'gh' CLI not found. Install with: brew install gh" && exit 1)
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> Creating GitHub release $(TAG) and uploading $(XZ_IMAGE)..."
	gh release create $(TAG) $(XZ_IMAGE) \
		--repo $(GH_REPO) \
		--title "Talos $(TALOS_VERSION) for Raspberry Pi CM5" \
		--notes "Custom Talos Linux image for Raspberry Pi CM5 (D0/Rev1.1 compatible).\n\nIncludes:\n- sbc-raspberrypi overlay: $(SBC_RPI_VERSION)\n- iscsi-tools: $(ISCSI_TOOLS_VERSION)\n- util-linux-tools: $(UTIL_LINUX_VERSION)\n\nInstaller image: $(GHCR_IMAGE)\n\nFlash with:\n\`\`\`\nxzcat metal-$(ARCH).raw.xz | sudo dd of=/dev/rdiskN bs=4m\n\`\`\`"
	@echo "==> Release created!"

## publish: Full publish pipeline — installer + compress + push + release
publish: installer compress push-installer release

## flash-sd: Flash the disk image to a disk (usage: make flash-sd DISK=/dev/rdisk4)
flash-sd:
	@test -n "$(DISK)" || (echo "ERROR: DISK is required. On macOS use /dev/rdiskN (raw device). Usage: make flash-sd DISK=/dev/rdisk4" && exit 1)
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> Flashing $(XZ_IMAGE) to $(DISK) — THIS WILL ERASE THE DISK!"
	@echo "    Press Ctrl-C within 5 seconds to abort..."
	@sleep 5
	xzcat $(XZ_IMAGE) | sudo dd of=$(DISK) bs=4m
	sudo sync
	@echo "==> Flash complete."

## pull-images: Pre-pull all images needed for the build
pull-images:
	$(DOCKER) pull $(IMAGER_IMAGE)
	$(DOCKER) pull $(INSTALLER_BASE)
	$(DOCKER) pull $(OVERLAY_IMAGE)
	$(DOCKER) pull $(ISCSI_TOOLS_IMAGE)
	$(DOCKER) pull $(UTIL_LINUX_IMAGE)

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

## clean: Remove build output
clean:
	rm -rf $(OUT_DIR)

## help: Show this help
help:
	@echo ""
	@echo "Talos RPI CM5 Builder — available targets:"
	@echo ""
	@grep -E '^## ' Makefile | sed 's/## /  /'
	@echo ""
	@echo "Variables (override with make VAR=value):"
	@echo "  TALOS_VERSION       = $(TALOS_VERSION)"
	@echo "  SBC_RPI_VERSION     = $(SBC_RPI_VERSION)"
	@echo "  ISCSI_TOOLS_VERSION = $(ISCSI_TOOLS_VERSION)"
	@echo "  UTIL_LINUX_VERSION  = $(UTIL_LINUX_VERSION)"
	@echo "  ARCH                = $(ARCH)"
	@echo "  DOCKER              = $(DOCKER)"
	@echo "  GHCR_ORG            = $(GHCR_ORG)"
	@echo "  GHCR_REPO           = $(GHCR_REPO)"
	@echo "  TAG                 = $(TAG)"
	@echo "  DISK                = (required for flash-sd, macOS: /dev/rdiskN)"
	@echo ""
