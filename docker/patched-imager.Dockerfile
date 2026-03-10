# Patched Talos imager — replaces arm64 vmlinuz AND kernel modules with our
# patched kernel build (macb RP1 PCIe TSTART flush fix).
#
# Why modules must be replaced too
# ─────────────────────────────────
# CONFIG_MODULE_SIG_FORCE=y: Talos rejects any module whose signature doesn't
# match the key baked into vmlinuz.  Each kernel build generates a unique
# throwaway signing key (certs/signing_key.pem).  If we swap only vmlinuz,
# the stock modules (signed by Sidero's key) fail to verify → critical
# modules like irq-bcm2712-mip.ko (the BCM2712 MSI interrupt controller)
# cannot load → RP1 probe fails ("Failed to allocate MSI-X vectors") →
# no macb ethernet → no network.
#
# Talos initramfs layout
# ──────────────────────
# initramfs.xz is actually a zstd-compressed cpio archive containing:
#   ./init          — Talos init binary
#   ./rootfs.sqsh   — zstd-compressed squashfs of the full rootfs
#
# Modules live inside rootfs.sqsh at /usr/lib/modules/<version>/.
# This Dockerfile:
#   1. Extracts rootfs.sqsh from the stock initramfs
#   2. Replaces the signed modules with our patched (properly-signed) copies
#   3. Repacks rootfs.sqsh → cpio → zstd → initramfs.xz
#   4. Copies both the patched vmlinuz and repacked initramfs into the imager
#
# Build args:
#   BASE_IMAGER   — official Talos imager, e.g. ghcr.io/siderolabs/imager:v1.12.4
#   KERNEL_IMAGE  — patched kernel OCI, e.g. ghcr.io/.../kernel:1.12.4-macb-fix
#
# Built by .github/workflows/build-patched-imager.yml
ARG BASE_IMAGER
ARG KERNEL_IMAGE

FROM ${KERNEL_IMAGE} AS patched-kernel
FROM ${BASE_IMAGER} AS base-imager

# ── Repack initramfs with patched modules ─────────────────────────────────────
FROM ubuntu:24.04 AS initramfs-repack

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        cpio zstd squashfs-tools kmod fakeroot && \
    rm -rf /var/lib/apt/lists/*

# Extract stock initramfs (zstd-compressed cpio)
COPY --from=base-imager /usr/install/arm64/initramfs.xz /tmp/initramfs.zst
RUN mkdir -p /tmp/initramfs && \
    cd /tmp/initramfs && \
    zstd -d < /tmp/initramfs.zst | cpio -idm

# Extract rootfs.sqsh (zstd-compressed squashfs)
RUN unsquashfs -d /tmp/rootfs /tmp/initramfs/rootfs.sqsh

# Bring in patched modules (signed with our kernel's key)
COPY --from=patched-kernel /usr/lib/modules /tmp/patched-modules

# Replace modules: keep the stock whitelist set, swap with patched copies
RUN set -eu; \
    STOCK_VER=$(ls /tmp/rootfs/usr/lib/modules/); \
    PATCH_VER=$(ls /tmp/patched-modules/); \
    echo "Stock kernel modules: ${STOCK_VER}"; \
    echo "Patched kernel modules: ${PATCH_VER}"; \
    # List every .ko in the stock rootfs and replace with patched equivalent \
    find /tmp/rootfs/usr/lib/modules/"${STOCK_VER}" -name '*.ko' | while read -r stock_ko; do \
        rel=${stock_ko#/tmp/rootfs/usr/lib/modules/"${STOCK_VER}"/}; \
        patched_ko="/tmp/patched-modules/${PATCH_VER}/${rel}"; \
        if [ -f "${patched_ko}" ]; then \
            cp "${patched_ko}" "${stock_ko}"; \
        else \
            echo "WARNING: no patched equivalent for ${rel} — removing"; \
            rm -f "${stock_ko}"; \
        fi; \
    done; \
    # Re-run depmod so modules.dep and friends match the new .ko files \
    depmod -b /tmp/rootfs "${STOCK_VER}"

# Repack rootfs.sqsh
RUN rm /tmp/initramfs/rootfs.sqsh && \
    fakeroot mksquashfs /tmp/rootfs /tmp/initramfs/rootfs.sqsh \
        -all-root -noappend -comp zstd -no-progress

# Repack initramfs (cpio + zstd, matching Talos build)
RUN cd /tmp/initramfs && \
    find . 2>/dev/null \
    | LC_ALL=c sort \
    | cpio --reproducible -H newc -o \
    | zstd -c -T0 -3 \
    > /tmp/initramfs-patched.xz

# ── Final imager with patched vmlinuz + initramfs ─────────────────────────────
FROM base-imager
COPY --from=patched-kernel /boot/vmlinuz /usr/install/arm64/vmlinuz
COPY --from=initramfs-repack /tmp/initramfs-patched.xz /usr/install/arm64/initramfs.xz
