# Build the Raspberry Pi Foundation kernel (rpi-6.18.y) using stock Talos
# config-arm64 as the base, with RPi CM5 hardware additions on top.
#
# Config approach (matches talos-builder's proven method):
# ─────────────────────────────────────────────────────────
# 1. Download stock Talos config-arm64 from siderolabs/pkgs.
#    This provides ALL Talos boot infrastructure: EFI, framebuffer, console,
#    fonts, initramfs decompression, cgroups, namespaces, module signing, etc.
# 2. Apply kernel/rpi-hardware-fragment — adds BCM2712/RP1 platform support,
#    16K pages, NVMe=y, bridge nftables, and CM5-relevant driver promotions.
# 3. Run olddefconfig to resolve rpi-6.18.y specific Kconfig differences.
#
# This is the opposite of the old approach (bcm2712_defconfig + tiny Talos
# fragment) which missed hundreds of Talos-required configs.
#
# Why RPi kernel instead of mainline?
# ────────────────────────────────────
# The RPi Foundation's rpi-6.18.y branch includes both macb PCIe TX stall
# fixes natively (commits e45c98d and 316d9fe71fb1), eliminating the need
# for our custom macb patch.  It also carries hardware-specific optimisations
# and driver backports for BCM2712/RP1 that don't exist in mainline.
#
# Build args:
#   RPI_KERNEL_REF   — git ref to build (branch, tag, or SHA)
#   TALOS_PKGS_REF   — siderolabs/pkgs git ref for stock config-arm64
#
# Built by .github/workflows/build-patched-imager.yml

ARG RPI_KERNEL_REF=rpi-6.18.y
ARG TALOS_PKGS_REF=v1.12.0

# ── Stage 1: Build kernel ────────────────────────────────────────────────────
FROM ubuntu:24.04 AS kernel-build

ARG RPI_KERNEL_REF
ARG TALOS_PKGS_REF

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential bc bison flex libssl-dev libelf-dev \
        ca-certificates git kmod cpio python3 rsync wget && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Shallow clone at the target ref — works for branches, tags, and SHAs.
# For SHA refs, GitHub requires fetching the specific commit.
RUN git clone --depth=1 --branch="${RPI_KERNEL_REF}" \
        https://github.com/raspberrypi/linux.git /build/linux || \
    ( git clone --depth=1 https://github.com/raspberrypi/linux.git /build/linux && \
      cd /build/linux && git fetch --depth=1 origin "${RPI_KERNEL_REF}" && \
      git checkout FETCH_HEAD )

# Download stock Talos config-arm64 — this is the proven base that includes
# all Talos boot infrastructure (EFI, framebuffer, console, fonts, cgroups, etc.)
RUN wget -q -O /build/config-arm64 \
    "https://raw.githubusercontent.com/siderolabs/pkgs/${TALOS_PKGS_REF}/kernel/build/config-arm64"

# Copy RPi hardware fragment
COPY kernel/rpi-hardware-fragment /build/rpi-hardware-fragment

WORKDIR /build/linux

# Start from stock Talos config-arm64, merge RPi hardware additions, resolve
# any Kconfig differences between mainline and rpi-6.18.y
RUN cp /build/config-arm64 .config && \
    scripts/kconfig/merge_config.sh -m .config /build/rpi-hardware-fragment && \
    make ARCH=arm64 olddefconfig

# Verify critical configs survived olddefconfig for the RPi kernel tree.
# Stock Talos config + RPi fragment should produce all of these, but verify
# in case rpi-6.18.y Kconfig removes or renames something.
RUN set -eu; FAIL=0; \
    check() { \
      val=$(grep "^$1=" .config 2>/dev/null || true); \
      if [ -z "$val" ]; then \
        echo "MISSING: $1 (forcing $2)"; \
        scripts/config --set-val "$1" "$2"; FAIL=1; \
      else echo "OK: $val"; fi; \
    }; \
    echo "=== Config verification after olddefconfig ==="; \
    echo "--- Talos boot infrastructure (from stock config-arm64) ---"; \
    check CONFIG_EFI y; \
    check CONFIG_EFI_STUB y; \
    check CONFIG_BLK_DEV_INITRD y; \
    check CONFIG_RD_ZSTD y; \
    check CONFIG_FRAMEBUFFER_CONSOLE y; \
    check CONFIG_FB_EFI y; \
    check CONFIG_DUMMY_CONSOLE y; \
    check CONFIG_DRM_FBDEV_EMULATION y; \
    check CONFIG_VT y; \
    check CONFIG_VT_CONSOLE y; \
    check CONFIG_FONT_SUPPORT y; \
    check CONFIG_MODULE_SIG_FORCE y; \
    check CONFIG_OVERLAY_FS y; \
    check CONFIG_SQUASHFS_ZSTD y; \
    echo "--- RPi hardware (from rpi-hardware-fragment) ---"; \
    check CONFIG_ARM64_16K_PAGES y; \
    check CONFIG_BLK_DEV_NVME y; \
    check CONFIG_FIRMWARE_RP1 y; \
    check CONFIG_MFD_RP1 y; \
    check CONFIG_BCM2712_IOMMU y; \
    check CONFIG_IKCONFIG y; \
    if [ "$FAIL" -ne 0 ]; then \
      echo "--- Re-running olddefconfig after fixes ---"; \
      make ARCH=arm64 olddefconfig; \
    fi; \
    echo "=== Final critical config state ==="; \
    grep -E 'CONFIG_EFI=|CONFIG_EFI_STUB=|CONFIG_BLK_DEV_INITRD=|CONFIG_RD_ZSTD=|CONFIG_FRAMEBUFFER_CONSOLE=|CONFIG_FB_EFI=|CONFIG_VT=|CONFIG_VT_CONSOLE=|CONFIG_FONT_SUPPORT=|CONFIG_ARM64_16K_PAGES=|CONFIG_BLK_DEV_NVME=|CONFIG_FIRMWARE_RP1=|CONFIG_MFD_RP1=' .config || true

# Build kernel image, modules, and BCM2712 device trees.
# DTBs must be built from the same kernel source to match driver DT bindings.
# The sbc-raspberrypi overlay ships DTBs compiled from an older kernel, which
# can cause NULL pointer crashes in drivers that expect newer DT properties
# (e.g. RP1 southbridge on the CM5).
RUN make ARCH=arm64 -j"$(nproc)" Image modules dtbs

# Install modules (stripped, no source/build symlinks)
RUN make ARCH=arm64 modules_install \
        INSTALL_MOD_PATH=/install/usr \
        INSTALL_MOD_STRIP=1 && \
    rm -f /install/usr/lib/modules/*/build \
          /install/usr/lib/modules/*/source

# Copy kernel image and config (config saved for debugging)
RUN mkdir -p /install/boot && \
    cp arch/arm64/boot/Image /install/boot/vmlinuz && \
    cp .config /install/boot/config

# Copy BCM2712 DTBs (all RPi 5 / CM5 variants)
RUN mkdir -p /install/boot/dtbs && \
    cp arch/arm64/boot/dts/broadcom/bcm2712*.dtb /install/boot/dtbs/

# ── Stage 2: Minimal output image ────────────────────────────────────────────
# Matches the layout expected by patched-imager.Dockerfile:
#   /boot/vmlinuz
#   /boot/config
#   /boot/dtbs/bcm2712*.dtb   — BCM2712 device trees matching the kernel
#   /usr/lib/modules/<version>/
FROM scratch AS kernel
COPY --from=kernel-build /install/boot/vmlinuz /boot/vmlinuz
COPY --from=kernel-build /install/boot/config /boot/config
COPY --from=kernel-build /install/boot/dtbs /boot/dtbs
COPY --from=kernel-build /install/usr/lib/modules /usr/lib/modules
