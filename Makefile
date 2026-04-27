# ------------------------------------------------------------------------------
# Talos Linux — Custom Image Builder for Raspberry Pi CM4/CM5
# Board: DeskPi Super6C (CM4IO-compatible carrier) and other CM4/CM5 boards
# ------------------------------------------------------------------------------

# --- Versions ------------------------------------------------------------------
TALOS_VERSION        ?= v1.12.7
ISCSI_TOOLS_VERSION  ?= v0.2.0
UTIL_LINUX_VERSION   ?= 2.41.2
LINUX_KERNEL_VERSION ?= 6.18.24
CUSTOM_INSTALLER_BASE ?= ghcr.io/wheetazlab/rpi-talos:v1.12.7-k-6.18.24-macb
CUSTOM_OVERLAY_IMAGE  ?= ghcr.io/wheetazlab/sbc-raspberrypi:pr88

# --- Build config --------------------------------------------------------------
ARCH        ?= arm64
OUT_DIR     ?= _out
OVERLAY     := rpi_generic
DOCKER      ?= podman
# Allocate a TTY only when running interactively (not in CI)
TTY_FLAG    := $(shell [ -t 0 ] && echo "-t" || echo "")

# Extra kernel args — pass as a space-separated list of --extra-kernel-arg="..." flags
# e.g. make build EXTRA_KERNEL_ARGS='--extra-kernel-arg="cma=256M"'
EXTRA_KERNEL_ARGS ?=

# --- GHCR publish config -------------------------------------------------------
GHCR_ORG        ?= wheetazlab
GHCR_REPO       ?= talos-rpi-cm5-installer
# INSTALLER_TAG lets CI override the destination image tag (e.g. v1.12.6-lite)
# without changing TALOS_VERSION which must match the upstream installer-base tag.
INSTALLER_TAG   ?= $(TALOS_VERSION)
GHCR_IMAGE      := ghcr.io/$(GHCR_ORG)/$(GHCR_REPO):$(INSTALLER_TAG)

# --- Release config ------------------------------------------------------------
# TAG is used for `make release` — override if you want a custom tag.
# e.g. make release TAG=v1.12.6-1
TAG             ?= $(TALOS_VERSION)
GH_REPO         ?= $(GHCR_ORG)/talos-rpi-cm5-builder

# --- Image refs ----------------------------------------------------------------
IMAGER_IMAGE        := ghcr.io/siderolabs/imager:$(TALOS_VERSION)
INSTALLER_BASE      := $(if $(CUSTOM_INSTALLER_BASE),$(CUSTOM_INSTALLER_BASE),ghcr.io/siderolabs/installer-base:$(TALOS_VERSION))
OVERLAY_IMAGE       := $(CUSTOM_OVERLAY_IMAGE)
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
	@echo "==> Building Talos $(TALOS_VERSION) image for RPI CM5 (overlay: $(OVERLAY_IMAGE))"
	$(DOCKER) run --rm $(TTY_FLAG) \
		-v $(CURDIR)/$(OUT_DIR):/out \
		-v /dev:/dev \
		--privileged \
		$(IMAGER_IMAGE) $(OVERLAY) \
		--base-installer-image="$(INSTALLER_BASE)" \
		--overlay-image="$(OVERLAY_IMAGE)" \
		--overlay-name="$(OVERLAY)" \
		--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
		--system-extension-image="$(UTIL_LINUX_IMAGE)" \
		$(EXTRA_KERNEL_ARGS) \
		--arch $(ARCH)
	@echo ""
	@echo "==> Build complete!"
	@ls -lh $(OUT_DIR)/
	@echo ""
	@echo "Image: $(XZ_IMAGE)"

## installer: Build the Talos installer OCI image (used for talosctl upgrade)
installer: $(OUT_DIR)
	@echo "==> Building Talos installer image for RPI CM4/CM5"
	$(DOCKER) run --rm $(TTY_FLAG) \
		-v $(CURDIR)/$(OUT_DIR):/out \
		-v /dev:/dev \
		--privileged \
		$(IMAGER_IMAGE) installer \
		--base-installer-image="$(INSTALLER_BASE)" \
		--overlay-image="$(OVERLAY_IMAGE)" \
		--overlay-name="$(OVERLAY)" \
		--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
		--system-extension-image="$(UTIL_LINUX_IMAGE)" \
		$(EXTRA_KERNEL_ARGS) \
		--arch $(ARCH)
	@echo "==> Installer image saved to $(INSTALLER_TAR)"

## compress: No-op — imager already outputs .raw.xz directly
compress:
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> $(XZ_IMAGE) already compressed (imager outputs .xz directly):" && ls -lh $(XZ_IMAGE)

## push-installer: Load installer OCI tar, tag and push to ghcr.io/$(GHCR_ORG)
push-installer:
	@test -f "$(INSTALLER_TAR)" || (echo "ERROR: $(INSTALLER_TAR) not found. Run 'make installer' first." && exit 1)
	@echo "==> Loading $(INSTALLER_TAR) into $(DOCKER)..."; \
	LOADED_IMAGE=$$($(DOCKER) load -i $(INSTALLER_TAR) 2>&1 | sed -n -E 's/^Loaded image(s)?: //p' | tail -n 1); \
	if [ -z "$$LOADED_IMAGE" ]; then \
		LOADED_IMAGE="$(INSTALLER_BASE)"; \
	fi; \
	echo "==> Loaded installer image: $$LOADED_IMAGE"; \
	$(DOCKER) tag "$$LOADED_IMAGE" $(GHCR_IMAGE) && \
	echo "==> Pushing $(GHCR_IMAGE)..."; \
	$(DOCKER) push $(GHCR_IMAGE); \
	echo "==> Push complete!"

## release: Create a GitHub release and upload the .raw.xz image (requires gh CLI)
release:
	@command -v gh >/dev/null 2>&1 || (echo "ERROR: 'gh' CLI not found. Install with: brew install gh" && exit 1)
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> Deleting existing release $(TAG) if present..."
	@gh release delete $(TAG) --repo $(GH_REPO) --yes 2>/dev/null || true
	@echo "==> Creating GitHub release $(TAG) and uploading $(XZ_IMAGE)..."
	gh release create $(TAG) $(XZ_IMAGE) \
		--repo $(GH_REPO) \
		--title "Talos $(TALOS_VERSION) for Raspberry Pi CM5" \
		--notes "Custom Talos Linux image for Raspberry Pi CM4/CM5 (rpi_generic overlay — CM4IO/CM5IO/Pi5 compatible).\n\nIncludes:\n- sbc-raspberrypi overlay: $(CUSTOM_OVERLAY_IMAGE)\n- iscsi-tools: $(ISCSI_TOOLS_VERSION)\n- util-linux-tools: $(UTIL_LINUX_VERSION)\n\nInstaller image: $(GHCR_IMAGE)\n\nFlash with:\n\`\`\`\nxzcat metal-$(ARCH).raw.xz | sudo dd of=/dev/rdiskN bs=4m\n\`\`\`"
	@echo "==> Release created!"

## publish: Full pipeline — build image, build installer, push to GHCR, create release
publish: build installer push-installer release

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
	@echo "  TALOS_VERSION         = $(TALOS_VERSION)"
	@echo "  ISCSI_TOOLS_VERSION   = $(ISCSI_TOOLS_VERSION)"
	@echo "  UTIL_LINUX_VERSION    = $(UTIL_LINUX_VERSION)"
	@echo "  ARCH                  = $(ARCH)"
	@echo "  DOCKER                = $(DOCKER)"
	@echo "  GHCR_ORG              = $(GHCR_ORG)"
	@echo "  GHCR_REPO             = $(GHCR_REPO)"
	@echo "  TAG                   = $(TAG)"
	@echo "  CUSTOM_INSTALLER_BASE = $(CUSTOM_INSTALLER_BASE)"
	@echo "  CUSTOM_OVERLAY_IMAGE  = $(CUSTOM_OVERLAY_IMAGE)"
	@echo "  DISK                  = (required for flash-sd, macOS: /dev/rdiskN)"
	@echo ""
