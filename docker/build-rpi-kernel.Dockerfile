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
        git kmod cpio python3 rsync && \
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

# Build kernel image + modules (skip DTBs — provided by sbc-raspberrypi overlay)
RUN make ARCH=arm64 -j"$(nproc)" Image modules

# Install modules (stripped, no source/build symlinks)
RUN make ARCH=arm64 modules_install \
        INSTALL_MOD_PATH=/install/usr \
        INSTALL_MOD_STRIP=1 && \
    rm -f /install/usr/lib/modules/*/build \
          /install/usr/lib/modules/*/source

# Copy kernel image
RUN mkdir -p /install/boot && \
    cp arch/arm64/boot/Image /install/boot/vmlinuz

# ── Stage 2: Minimal output image ────────────────────────────────────────────
# Matches the layout expected by patched-imager.Dockerfile:
#   /boot/vmlinuz
#   /usr/lib/modules/<version>/
FROM scratch
COPY --from=kernel-build /install/boot/vmlinuz /boot/vmlinuz
COPY --from=kernel-build /install/usr/lib/modules /usr/lib/modules
