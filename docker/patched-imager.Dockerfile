# Patched Talos imager — replaces arm64 vmlinuz with the macb RP1 PCIe TSTART fix.
#
# CONFIG_MACB=y in the Talos arm64 kernel config: macb is compiled directly into
# vmlinuz (not a loadable .ko module). Replacing vmlinuz is therefore the ONLY
# change required. No initramfs rebuild, no module signing, no Go recompilation.
#
# Build args:
#   BASE_IMAGER   — official Talos imager, e.g. ghcr.io/siderolabs/imager:v1.12.4
#   KERNEL_IMAGE  — patched kernel OCI, e.g. ghcr.io/.../kernel:1.12.4-macb-fix
#
# Built by .github/workflows/build-patched-imager.yml
ARG BASE_IMAGER
ARG KERNEL_IMAGE

FROM ${KERNEL_IMAGE} AS patched-kernel
FROM ${BASE_IMAGER}

# Swap arm64 vmlinuz only — amd64 path and initramfs are untouched.
COPY --from=patched-kernel /boot/vmlinuz /usr/install/arm64/vmlinuz
