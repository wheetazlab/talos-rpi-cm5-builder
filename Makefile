# ------------------------------------------------------------------------------
# Talos Linux — Custom Image Builder for Raspberry Pi CM5
# Board: DeskPi Super6C (CM4IO-compatible carrier)
# ------------------------------------------------------------------------------

# --- Versions ------------------------------------------------------------------
TALOS_VERSION        ?= v1.12.5
SBC_RPI_VERSION      ?= v0.2.0
ISCSI_TOOLS_VERSION  ?= v0.2.0
UTIL_LINUX_VERSION   ?= 2.41.2
UBOOT_VERSION        ?= v2026.04-rc1
RPI_KERNEL_REF       ?= rpi-6.18.y
TALOS_PKGS_REF       ?= v1.12.0
# PKGS_REF and LINUX_KERNEL_VERSION are retained for the stock publish workflow
# (release notes only — the stock flow uses the upstream Talos kernel, not ours).
PKGS_REF             ?= b1fc4c6
LINUX_KERNEL_VERSION ?= 6.18.9

# --- Build config --------------------------------------------------------------
ARCH        ?= arm64
OUT_DIR     ?= _out
OVERLAY     := rpi_5
DOCKER      ?= podman
# CM5_VARIANT: lite (no onboard eMMC) or emmc (has onboard eMMC)
# lite: blacklists sdhci_brcmstb to suppress mmc0 timeout errors
# emmc: no blacklist, eMMC controller stays active
CM5_VARIANT ?= lite
# Allocate a TTY only when running interactively (not in CI)
TTY_FLAG    := $(shell [ -t 0 ] && echo "-t" || echo "")

# Kernel args based on variant
ifeq ($(CM5_VARIANT),lite)
SDHCI_KERNEL_ARG := --extra-kernel-arg="module_blacklist=sdhci_brcmstb"
else
SDHCI_KERNEL_ARG :=
endif

# Extra kernel args — pass as a space-separated list of --extra-kernel-arg="..." flags
# e.g. make build EXTRA_KERNEL_ARGS='--extra-kernel-arg="cma=256M"'
EXTRA_KERNEL_ARGS ?=

# --- GHCR publish config -------------------------------------------------------
GHCR_ORG        ?= wheetazlab
GHCR_REPO       ?= talos-rpi-cm5-installer
# INSTALLER_TAG lets CI override the destination image tag (e.g. v1.12.5-lite)
# without changing TALOS_VERSION which must match the upstream installer-base tag.
INSTALLER_TAG   ?= $(TALOS_VERSION)
GHCR_IMAGE      := ghcr.io/$(GHCR_ORG)/$(GHCR_REPO):$(INSTALLER_TAG)

# --- Release config ------------------------------------------------------------
# TAG is used for `make release` — override if you want a custom tag.
# e.g. make release TAG=v1.12.5-1
TAG             ?= $(TALOS_VERSION)
GH_REPO         ?= $(GHCR_ORG)/talos-rpi-cm5-builder

# --- Custom kernel overrides (RPi Foundation kernel) --------------------------
# The RPi Foundation's rpi-6.18.y kernel includes native macb PCIe TX stall
# fixes for RP1, eliminating the need for our custom macb patch.  It also
# carries BCM2712/RP1-specific optimizations not present in mainline.
#
# CI automatically sets CUSTOM_IMAGER to the RPi kernel imager tag built by
# the build-patched-imager workflow.  Run that workflow once per kernel ref.
#
# For local builds, override manually:
#   make build CUSTOM_IMAGER=ghcr.io/<owner>/talos-rpi-cm5-builder/imager:1.12.5-rpi-kernel
#   make build CUSTOM_OVERLAY=ghcr.io/<owner>/talos-rpi-cm5-builder/overlay:1.12.5-rpi-kernel
#
CUSTOM_IMAGER           ?=
CUSTOM_OVERLAY          ?=

# --- Image refs ----------------------------------------------------------------
IMAGER_IMAGE        := $(if $(CUSTOM_IMAGER),$(CUSTOM_IMAGER),ghcr.io/siderolabs/imager:$(TALOS_VERSION))
INSTALLER_BASE      := ghcr.io/siderolabs/installer-base:$(TALOS_VERSION)
OVERLAY_IMAGE       := $(if $(CUSTOM_OVERLAY),$(CUSTOM_OVERLAY),ghcr.io/siderolabs/sbc-raspberrypi:$(SBC_RPI_VERSION))
ISCSI_TOOLS_IMAGE   := ghcr.io/siderolabs/iscsi-tools:$(ISCSI_TOOLS_VERSION)
UTIL_LINUX_IMAGE    := ghcr.io/siderolabs/util-linux-tools:$(UTIL_LINUX_VERSION)

# --- Output files --------------------------------------------------------------
# NOTE: The Talos imager outputs .raw.xz directly — no separate compress step needed
XZ_IMAGE          := $(OUT_DIR)/metal-$(ARCH).raw.xz
INSTALLER_TAR     := $(OUT_DIR)/installer-$(ARCH).tar
UBOOT_BIN         := $(OUT_DIR)/u-boot-nvme.bin
UBOOT_PATCH       := $(CURDIR)/patches/uboot-rpi5-nvme.patch

# -------------------------------------------------------------------------------

.PHONY: all build compress flash-sd installer push-installer release publish pull-images uboot-build uboot-inject uboot clean help

all: build

## build: Build the custom Talos disk image for RPI CM5
build: $(OUT_DIR)
	@echo "==> Building Talos $(TALOS_VERSION) image for RPI CM5 (sbc-raspberrypi $(SBC_RPI_VERSION))"
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
		$(SDHCI_KERNEL_ARG) \
		$(EXTRA_KERNEL_ARGS) \
		--arch $(ARCH)
	@echo ""
	@echo "==> Build complete!"
	@ls -lh $(OUT_DIR)/
	@echo ""
	@echo "Image: $(XZ_IMAGE)"

## installer: Build the Talos installer OCI image (used for talosctl upgrade)
installer: $(OUT_DIR)
	@echo "==> Building Talos installer image for RPI CM5"
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
		$(SDHCI_KERNEL_ARG) \
		$(EXTRA_KERNEL_ARGS) \
		--arch $(ARCH)
	@echo "==> Installer image saved to $(INSTALLER_TAR)"

## compress: No-op — imager already outputs .raw.xz directly
compress:
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@echo "==> $(XZ_IMAGE) already compressed (imager outputs .xz directly):" && ls -lh $(XZ_IMAGE)

## push-installer: Load installer OCI tar, inject NVMe U-Boot, tag and push to ghcr.io/$(GHCR_ORG)
push-installer:
	@test -f "$(INSTALLER_TAR)" || (echo "ERROR: $(INSTALLER_TAR) not found. Run 'make installer' first." && exit 1)
	@test -f "$(UBOOT_BIN)" || (echo "ERROR: $(UBOOT_BIN) not found. Run 'make uboot-build' first." && exit 1)
	@echo "==> Loading $(INSTALLER_TAR) into $(DOCKER)..."
	$(DOCKER) load -i $(INSTALLER_TAR)
	@echo "==> Injecting NVMe U-Boot into installer image..."
	@$(DOCKER) rm -f talos-installer-uboot-patch 2>/dev/null || true; \
		$(DOCKER) create --name talos-installer-uboot-patch ghcr.io/siderolabs/installer-base:$(TALOS_VERSION) >/dev/null && \
		$(DOCKER) cp $(UBOOT_BIN) talos-installer-uboot-patch:/overlay/artifacts/arm64/u-boot/rpi_generic/u-boot.bin && \
		$(DOCKER) commit talos-installer-uboot-patch ghcr.io/siderolabs/installer-base:$(TALOS_VERSION) >/dev/null && \
		$(DOCKER) rm talos-installer-uboot-patch >/dev/null
	@echo "==> Tagging as $(GHCR_IMAGE)"
	$(DOCKER) tag ghcr.io/siderolabs/installer-base:$(TALOS_VERSION) $(GHCR_IMAGE)
	@echo "==> Pushing $(GHCR_IMAGE)"
	$(DOCKER) push $(GHCR_IMAGE)
	@echo "==> Push complete!"

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
		--notes "Custom Talos Linux image for Raspberry Pi CM5 (D0/Rev1.1 compatible).\n\nIncludes:\n- sbc-raspberrypi overlay: $(SBC_RPI_VERSION)\n- iscsi-tools: $(ISCSI_TOOLS_VERSION)\n- util-linux-tools: $(UTIL_LINUX_VERSION)\n\nInstaller image: $(GHCR_IMAGE)\n\nFlash with:\n\`\`\`\nxzcat metal-$(ARCH).raw.xz | sudo dd of=/dev/rdiskN bs=4m\n\`\`\`"
	@echo "==> Release created!"

## publish: Full pipeline — build image, inject U-Boot, build installer, push to GHCR, create release
publish: build uboot-build uboot-inject installer push-installer release

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

## uboot-build: Build patched U-Boot with NVMe/PCIe support for RPi5/CM5 (native arm64 — no cross-compiler)
uboot-build: $(OUT_DIR)
	DOCKER=$(DOCKER) UBOOT_VERSION=$(UBOOT_VERSION) ./scripts/build-uboot.sh
	@echo "==> U-Boot binary ready: $(UBOOT_BIN)"

## uboot-inject: Inject patched U-Boot into the disk image file (_out/metal-arm64.raw.xz)
uboot-inject:
	@test -f "$(UBOOT_BIN)" || (echo "ERROR: $(UBOOT_BIN) not found. Run 'make uboot-build' first." && exit 1)
	@test -f "$(XZ_IMAGE)" || (echo "ERROR: $(XZ_IMAGE) not found. Run 'make build' first." && exit 1)
	@./scripts/inject-uboot.sh

## uboot: Build patched U-Boot AND inject into disk image in one step
uboot: uboot-build uboot-inject

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
	@echo "  UBOOT_VERSION       = $(UBOOT_VERSION)"
	@echo "  CM5_VARIANT         = $(CM5_VARIANT)  (lite or emmc)"
	@echo "  DISK                = (required for flash-sd, macOS: /dev/rdiskN)"
	@echo ""
