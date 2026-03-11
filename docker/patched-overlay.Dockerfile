# check=skip=InvalidDefaultArgInFrom
# Patched SBC overlay — replaces BCM2712 DTBs with kernel-matched versions.
#
# Why this is needed
# ──────────────────
# The sbc-raspberrypi overlay ships DTBs compiled from an older kernel tree.
# When using the RPi Foundation's rpi-6.18.y kernel, the RP1 MFD driver
# expects device-tree bindings that may differ from the overlay's vintage.
# A mismatch causes NULL pointer dereferences during RP1 probe (the
# southbridge that provides Ethernet, USB, GPIO on BCM2712/CM5).
#
# This Dockerfile takes the stock sbc-raspberrypi overlay and replaces only
# the BCM2712 DTBs (artifacts/rpi_5/*.dtb) with freshly-compiled versions
# from the same kernel source.  Firmware files and DT overlays (.dtbo) are
# kept from the stock overlay.
#
# Build args:
#   BASE_OVERLAY   — stock overlay, e.g. ghcr.io/siderolabs/sbc-raspberrypi:v0.2.0
#   KERNEL_IMAGE   — custom kernel OCI that includes /boot/dtbs/bcm2712*.dtb

ARG BASE_OVERLAY
ARG KERNEL_IMAGE

FROM ${KERNEL_IMAGE} AS patched-kernel
FROM ${BASE_OVERLAY}

# Replace BCM2712 DTBs with kernel-matched versions
COPY --from=patched-kernel /boot/dtbs/bcm2712*.dtb /artifacts/rpi_5/
