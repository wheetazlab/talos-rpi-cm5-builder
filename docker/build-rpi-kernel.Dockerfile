# Build the Raspberry Pi Foundation kernel (rpi-6.18.y) with Talos-required
# config options.  Produces /boot/vmlinuz and /usr/lib/modules/<ver>/ in the
# same layout expected by patched-imager.Dockerfile.
#
# Why RPi kernel instead of mainline?
# ────────────────────────────────────
# The RPi Foundation's rpi-6.18.y branch includes both macb PCIe TX stall
# fixes natively (commits e45c98d and 316d9fe71fb1), eliminating the need
# for our custom macb patch.  It also carries hardware-specific optimisations
# and driver backports for BCM2712/RP1 that don't exist in mainline.
#
# Build args:
#   RPI_KERNEL_REF  — git ref to build (branch, tag, or SHA)
#                     e.g. "rpi-6.18.y" or "abc1234"
#
# Built by .github/workflows/build-patched-imager.yml

ARG RPI_KERNEL_REF=rpi-6.18.y

# ── Stage 1: Build kernel ────────────────────────────────────────────────────
FROM ubuntu:24.04 AS kernel-build

ARG RPI_KERNEL_REF

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential bc bison flex libssl-dev libelf-dev \
        ca-certificates git kmod cpio python3 rsync && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Shallow clone at the target ref — works for branches, tags, and SHAs.
# For SHA refs, GitHub requires fetching the specific commit.
RUN git clone --depth=1 --branch="${RPI_KERNEL_REF}" \
        https://github.com/raspberrypi/linux.git /build/linux || \
    ( git clone --depth=1 https://github.com/raspberrypi/linux.git /build/linux && \
      cd /build/linux && git fetch --depth=1 origin "${RPI_KERNEL_REF}" && \
      git checkout FETCH_HEAD )

# Copy Talos config fragment
COPY kernel/talos-config-fragment /build/talos-config-fragment

WORKDIR /build/linux

# Start from bcm2712_defconfig, merge Talos options, resolve dependencies
RUN make ARCH=arm64 bcm2712_defconfig && \
    scripts/kconfig/merge_config.sh -m .config /build/talos-config-fragment && \
    make ARCH=arm64 olddefconfig

# Verify boot-critical configs survived olddefconfig resolution.
# If any required config is missing, force it and re-run olddefconfig.
RUN set -eu; FAIL=0; \
    check() { \
      val=$(grep "^$1=" .config 2>/dev/null || true); \
      if [ -z "$val" ]; then \
        echo "MISSING: $1 (forcing $2)"; \
        scripts/config --set-val "$1" "$2"; FAIL=1; \
      else echo "OK: $val"; fi; \
    }; \
    echo "=== Config verification after olddefconfig ==="; \
    check CONFIG_EFI y; \
    check CONFIG_EFI_STUB y; \
    check CONFIG_BLK_DEV_INITRD y; \
    check CONFIG_FRAMEBUFFER_CONSOLE y; \
    check CONFIG_FB_EFI y; \
    check CONFIG_DUMMY_CONSOLE y; \
    check CONFIG_DRM_FBDEV_EMULATION y; \
    check CONFIG_IKCONFIG y; \
    if [ "$FAIL" -ne 0 ]; then \
      echo "--- Re-running olddefconfig after fixes ---"; \
      make ARCH=arm64 olddefconfig; \
    fi; \
    echo "=== Final critical config state ==="; \
    grep -E 'CONFIG_EFI=|CONFIG_EFI_STUB=|CONFIG_BLK_DEV_INITRD=|CONFIG_FRAMEBUFFER_CONSOLE=|CONFIG_FB_EFI=|CONFIG_DUMMY_CONSOLE=|CONFIG_DRM_FBDEV_EMULATION=|CONFIG_IKCONFIG=' .config || true

# Build kernel image + modules (skip DTBs — provided by sbc-raspberrypi overlay)
RUN make ARCH=arm64 -j"$(nproc)" Image modules

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

# ── Stage 2: Minimal output image ────────────────────────────────────────────
# Matches the layout expected by patched-imager.Dockerfile:
#   /boot/vmlinuz
#   /usr/lib/modules/<version>/
FROM scratch AS kernel
COPY --from=kernel-build /install/boot/vmlinuz /boot/vmlinuz
COPY --from=kernel-build /install/boot/config /boot/config
COPY --from=kernel-build /install/usr/lib/modules /usr/lib/modules
