# talos-rpi-cm5-builder

[![Build and Publish](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml/badge.svg)](https://github.com/wheetazlab/talos-rpi-cm5-builder/actions/workflows/publish.yml)

Custom [Talos Linux](https://www.talos.dev/) image builder for **Raspberry Pi CM5** on CM4IO-compatible carrier boards (e.g. DeskPi Super6C).

Includes a patched U-Boot with NVMe/PCIe support, `iscsi-tools` and `util-linux-tools` system extensions, and the latest `sbc-raspberrypi` overlay with proper DTB support for CM5 (including D0-stepping / Rev 1.1 boards). Also ships a patched kernel with two network fixes: a PCIe posted-write fence for the `macb` Ethernet driver's TSTART register (preventing intermittent TX stalls on the RP1 southbridge), and BCM54213PE PHY EEE/LPI MAC support plus AutogrEEEn disable (preventing silent packet loss when the PHY enters Low Power Idle without matching MAC-side handling).

## Background

Talos ≤ v1.12.2 could not boot on CM5 boards (Rev 1.1 / D0 BCM2712 stepping) due to a missing `bcm2712-rpi-cm5-*.dtb` and a broken `bcm2712d0.dtbo` overlay. This was resolved in [siderolabs/sbc-raspberrypi#79](https://github.com/siderolabs/sbc-raspberrypi/pull/79), merged Feb 2026, and first released as `sbc-raspberrypi v0.1.9`. This repo uses `v0.2.0` (latest).

NVMe boot support is provided by a patched U-Boot (`v2026.04-rc1`) with BCM2712 PCIe driver support, contributed by [@appkins](https://github.com/appkins) via [siderolabs/sbc-raspberrypi#81](https://github.com/siderolabs/sbc-raspberrypi/issues/81). (this is currently a pending PR for the sbc-raspberry repo at)

Reference issue: [siderolabs/talos#12748](https://github.com/siderolabs/talos/issues/12748)

### macb RP1 PCIe TSTART fence fix (kernel patch)

Talos 1.12.x ships kernel 6.18.x. On CM5, the `macb` Ethernet driver (Cadence GEM) sits behind the RP1 southbridge over PCIe. PCIe uses **posted writes** for MMIO — the CPU fires the write and continues without confirmation. Under load, the write of `NCR |= TSTART` (transmit start) can be silently dropped by RP1, leaving the TX ring permanently stalled with **no kernel error, no watchdog timeout, and PHY link staying UP**. The node becomes unreachable on the network while still responding to ping from the local side and appearing healthy from the kernel's perspective.

The fix is a **PCIe read-after-write barrier**: immediately after each TSTART write, read NCR back via `readl()` (non-relaxed). On arm64, `readl()` includes a DSB (Data Synchronization Barrier) that stalls the CPU pipeline until the PCIe non-posted read completes — guaranteeing all prior posted writes from the same requester have been delivered. After `readl()` returns, TSTART is guaranteed to have reached RP1 and the CPU cannot speculatively race ahead into the next TX path.

```c
macb_writel(bp, NCR, macb_readl(bp, NCR) | MACB_BIT(TSTART));
(void)readl(bp->regs + MACB_NCR);  /* DSB + PCIe non-posted read → fence TSTART to RP1 */
```

This is applied in both `macb_start_xmit()` (per-packet TX path) and `macb_tx_restart()` (NAPI retry path). See [`patches/net-macb-flush-TSTART-write-to-RP1-over-PCIe.patch`](patches/net-macb-flush-TSTART-write-to-RP1-over-PCIe.patch).

**Why a custom kernel?** `CONFIG_MACB=y` — macb is compiled directly into `vmlinuz`, not a loadable module. There is no `macb.ko` to replace. The only fix is rebuilding `vmlinuz` and the matching kernel modules, which is what the patched imager workflow does.

**Why modules too?** `CONFIG_MODULE_SIG_FORCE=y` — Talos rejects any module whose signature doesn't match the key baked into vmlinuz. Each kernel build auto-generates a unique signing key. If we only swap vmlinuz, stock modules (signed by Sidero's key) fail to verify. Critically, `irq-bcm2712-mip.ko` (`CONFIG_BCM2712_MIP=m`) is the MSI-X interrupt controller for BCM2712/RP1. Without it, RP1 probe fails → no macb ethernet → no network. The patched imager Dockerfile extracts `rootfs.sqsh` from the stock initramfs, replaces the kernel modules with properly-signed copies from our kernel build, and repacks everything.

**Why `readl()` not `macb_readl()`?** `macb_readl()` uses `readl_relaxed()`, which issues a PCIe non-posted read but does NOT include a CPU barrier — the CPU can speculatively re-enter the TX path before the read completes. `readl()` adds an arm64 DSB (Data Synchronization Barrier) that stalls the pipeline until the PCIe round-trip finishes. Under sustained TX load on RP1's PCIe link, this close-the-window guarantee matters. The Raspberry Pi downstream kernel ([`e45c98d`](https://github.com/raspberrypi/linux/commit/e45c98decbb16e58a79c7ec6fbe4374320e814f1)) uses a pre-write TSR read to flush posted writes; our patch uses a post-write NCR readback with full CPU synchronization, covering both TX start paths.

### BCM54213PE EEE / AutogrEEEn fix (kernel patches)

Talos 1.12.x on CM5 uses the BCM54213PE Gigabit PHY. By default this PHY enables **AutogrEEEn** — an autonomous mode that negotiates 802.3az EEE and asserts LPI (Low Power Idle) signaling toward the MAC without driver involvement. The upstream `macb` driver in Linux 6.18.x has no EEE/LPI MAC-side support: when the PHY asserts LPI, queued frames are silently dropped — PHY link stays UP, no kernel errors appear, and the node looks healthy but stops forwarding traffic.

The fix has two parts:

1. **macb EEE/LPI MAC support** — four patches backported from [raspberrypi/linux rpi-6.18.y PR #7270](https://github.com/raspberrypi/linux/pull/7270):
   - [`net-macb-rp1-0001-eee-lpi-stats.patch`](patches/net-macb-rp1-0001-eee-lpi-stats.patch) — LPI statistics counters
   - [`net-macb-rp1-0002-eee-lpi-impl.patch`](patches/net-macb-rp1-0002-eee-lpi-impl.patch) — TX LPI implementation, `macb_tx_lpi_wake()` in `macb_start_xmit()`
   - [`net-macb-rp1-0003-eee-ethtool.patch`](patches/net-macb-rp1-0003-eee-ethtool.patch) — ethtool EEE `get`/`set` ops
   - [`net-macb-rp1-0004-eee-enable-rp1.patch`](patches/net-macb-rp1-0004-eee-enable-rp1.patch) — adds `MACB_CAPS_EEE` to `raspberrypi_rp1_config`

2. **BCM54213PE AutogrEEEn disable** — [`net-phy-broadcom-disable-autogreeen.patch`](patches/net-phy-broadcom-disable-autogreeen.patch) adds a BCM54213PE-specific PHY dispatch entry and clears the AutogrEEEn bit during PHY config, giving the kernel driver full EEE control via standard ethtool.

> **Patch ordering note:** `net-macb-rp1-0002-eee-lpi-impl.patch` modifies `macb_start_xmit()` using lines added by the PCIe fence patch as context. `bldr` applies patches alphabetically — `net-macb-flush...` sorts before `net-macb-rp1-...` — so ordering is preserved. Do not rename patches in a way that breaks this.

Both network fixes are tracked at: [siderolabs/sbc-raspberrypi#82](https://github.com/siderolabs/sbc-raspberrypi/issues/82)

---

## ⚠️ EEPROM Requirement

**Before flashing, ensure your CM5 is running the latest bootloader EEPROM.** An outdated EEPROM can cause boot failures, NVMe detection issues, or hangs at the U-Boot logo that look like image problems but aren't.

### Check your current EEPROM version

Boot into Raspberry Pi OS and run:

```bash
sudo rpi-eeprom-update
```

### Update to latest

```bash
sudo apt update && sudo apt full-upgrade -y
sudo rpi-eeprom-update -a
sudo reboot
```

After reboot, verify with `sudo rpi-eeprom-update` — it should report no update needed.

### If the CM5 has never booted an OS

Flash Raspberry Pi OS to an SD card, boot from it once (this automatically updates the EEPROM), then proceed to flash Talos.

> **Why this matters:** NVMe boot and PCIe support depend on EEPROM firmware features added in late 2024. Boards shipped with older firmware may fail to enumerate NVMe devices in U-Boot regardless of the kernel/DTB configuration.

---

## Versions

| Component             | Version        |
|-----------------------|----------------|
| Talos Linux           | `v1.12.5`      |
| sbc-raspberrypi       | `v0.2.0`       |
| iscsi-tools extension | `v0.2.0`       |
| util-linux-tools      | `2.41.2`       |
| U-Boot                | `v2026.04-rc1` |

All versions are configurable — see [Customization](#customization).

---

## CI/CD

Images are built automatically on GitHub Actions using a native **Ubuntu arm64** runner — no cross-compilation needed.

Both workflow files use `github.repository_owner` for all GHCR paths — they are fully portable. Forks automatically publish to the forker's own GHCR namespace.

### Step 1 (prerequisite for patched kernel): Build Patched Imager (`build-patched-imager.yml`)

**Run this first** — it rebuilds the kernel with all `net-*.patch` fixes (PCIe TSTART fence + BCM54213PE EEE/AutogrEEEn) and produces a patched imager image. Only needs to run once per kernel version (i.e. once per Talos minor release). Skip this step if you only want a standard unpatched image.

**Trigger:** Manual only — **Actions → Build Patched Imager (macb RP1 EEE + PCIe fix) → Run workflow**

**What it does (no fork needed):**
1. Clones `siderolabs/pkgs` at the matching release branch (ephemeral, thrown away after the run)
2. Copies `patches/net-*.patch` (PCIe TSTART fence + 5 EEE patches) into the pkgs kernel patch directory
3. Runs `docker buildx build --target=kernel` via `siderolabs/bldr` — downloads Linux source, applies all upstream patches plus ours, compiles `vmlinuz` + kernel modules (~40–90 min on a 4-core arm64 runner)
4. Pushes the patched kernel OCI to GHCR: `ghcr.io/<your-username>/talos-rpi-cm5-builder/kernel:<ver>-eee-fix`
5. Builds `docker/patched-imager.Dockerfile` — takes the official Talos imager, replaces `vmlinuz` and repacks `initramfs.xz` with properly-signed kernel modules
6. Pushes the patched imager to GHCR: `ghcr.io/<your-username>/talos-rpi-cm5-builder/imager:<ver>-eee-fix`
7. Writes a job summary with the exact `custom_imager` tag to copy into the next step

### Step 2: Build and Publish (`publish.yml`)

The standard image build pipeline. Builds disk images and the upgrade installer for both CM5 variants.

**Triggers:**
- Push a version tag (e.g. `git tag v1.12.5 && git push --tags`) → full build + publish
- Manual run via **Actions → Build and Publish → Run workflow** with optional version override

**Pipeline jobs:**
1. **`resolve-version`** — resolves Talos version from tag/input/Makefile default; extracts extension metadata
2. **`build-uboot`** — builds the patched U-Boot binary once and caches it as an artifact
3. **`build` (matrix: `lite` + `emmc`)** — both variants build in parallel:
   - Downloads the pre-built U-Boot artifact
   - Builds disk image, injects U-Boot, builds installer
   - Pushes installer to GHCR tagged `:vX.Y.Z-lite` / `:vX.Y.Z-emmc`
   - Uploads `metal-arm64-lite.raw.xz` / `metal-arm64-emmc.raw.xz` as artifacts
4. **`release`** — downloads both artifacts and creates the GitHub release with both images attached

The patched imager tag is computed automatically from `github.repository_owner` and the resolved `TALOS_VERSION` — no manual input required. Step 2 always uses the patched kernel as long as step 1 has been run at least once for the current kernel version.

**Full sequence to publish a patched release:**
```
Step 1 (once per kernel version):
  Actions → Build Patched Imager → Run workflow
  ↓ wait ~90 min

Step 2 (every release):
  Actions → Build and Publish → Run workflow
  ↓ automatically uses ghcr.io/<your-username>/talos-rpi-cm5-builder/imager:<ver>-eee-fix
```

> **⚠️ Required GitHub permissions (org repos only)**
>
> If this repo is under a **GitHub Organization**, the default `GITHUB_TOKEN` cannot push to GHCR unless the org explicitly allows it. Without this, every push step will fail with `permission_denied: write_package`.
>
> Fix via API or UI:
> - **UI:** Organization → Settings → Actions → General → Workflow permissions → **Read and write permissions**
> - **CLI:**
> ```bash
> gh api --method PUT /orgs/<YOUR_ORG>/actions/permissions/workflow \
>   --field default_workflow_permissions=write \
>   --field can_approve_pull_request_reviews=true
> ```
> This only needs to be set once per organization.

---

## Prerequisites (local builds only)

- **Podman** or **Docker** (with privileged container support)
- **macOS** or **Linux** host (arm64 recommended for U-Boot build)
- `make`
- `gh` CLI for publishing: `brew install gh && gh auth login`

---

## Quick Start

### Download a release

Download from the [Releases page](https://github.com/wheetazlab/talos-rpi-cm5-builder/releases) — two variants are published per release:

| File | For |
|------|-----|
| `metal-arm64-lite.raw.xz` | CM5 Lite (no onboard eMMC) |
| `metal-arm64-emmc.raw.xz` | CM5 with onboard eMMC |

### Flash to SD card / eMMC

```bash
# macOS (replace <variant> with lite or emmc)
xzcat metal-arm64-<variant>.raw.xz | sudo dd of=/dev/rdiskN bs=4m

# Linux
xzcat metal-arm64-<variant>.raw.xz | sudo dd of=/dev/sdX bs=4M status=progress
```

Or with make (after building locally):
```bash
make flash-sd DISK=/dev/rdisk4
```

### eMMC via rpiboot

1. Set the CM5 into USB boot mode (check your carrier board manual for the jumper/button)
2. Connect via USB-C and run `sudo rpiboot`
3. Flash to the exposed eMMC disk


---

## Local Build

```bash
# Full pipeline (build image + U-Boot + inject + installer + push + release)
make publish

# Individual steps
make build        # Talos disk image → _out/metal-arm64.raw.xz
make uboot-build  # Patched U-Boot  → _out/u-boot-nvme.bin
make uboot-inject # Inject U-Boot into disk image
make installer    # Installer OCI   → _out/installer-arm64.tar
make release      # GitHub release with .raw.xz artifact
```

---

## Customization

```bash
# Different Talos version
make publish TALOS_VERSION=v1.12.4

# CM5 with onboard eMMC (disables sdhci_brcmstb blacklist)
make publish CM5_VARIANT=emmc

# Full override
make publish TALOS_VERSION=v1.12.4 SBC_RPI_VERSION=v0.2.0 CM5_VARIANT=lite
```

**`CM5_VARIANT`** controls a kernel arg applied at image build time (local builds only — CI always builds both):
- `lite` (default) — blacklists `sdhci_brcmstb` to suppress spurious `mmc0` interrupt timeout errors on CM5 Lite (no onboard eMMC)
- `emmc` — no blacklist, eMMC controller stays active

### Adding more extensions

Edit the `Makefile` and append additional `--system-extension-image` flags:

```makefile
--system-extension-image="$(ISCSI_TOOLS_IMAGE)" \
--system-extension-image="ghcr.io/siderolabs/gvisor:20260202.0" \
```

Browse available extensions: https://github.com/siderolabs/extensions

---

## Build Targets

```
make build          Build the raw disk image
make uboot-build    Build patched U-Boot with NVMe/PCIe support
make uboot-inject   Inject patched U-Boot into disk image
make uboot          Build + inject in one step
make installer      Build the Talos installer image (for talosctl upgrade)
make publish        Full pipeline: build → uboot → inject → installer → push → release
make flash-sd       Flash image to disk (requires DISK=/dev/rdiskN)
make pull-images    Pre-pull all required container images
make clean          Remove _out/ directory
make help           Show all targets and version variables
```

---

## What's in the image?

- Talos Linux kernel + initramfs (arm64) — **patched vmlinuz + modules** with macb RP1 PCIe TSTART fence + BCM54213PE EEE/AutogrEEEn fix
- **Patched U-Boot** (`v2026.04-rc1`) with BCM2712 PCIe driver — enables NVMe boot on CM5
- DTBs from `sbc-raspberrypi v0.2.0`:
  - `bcm2712-rpi-cm5-cm4io.dtb` ← CM4IO-compatible carriers (e.g. DeskPi Super6C)
  - `bcm2712-rpi-cm5-cm5io.dtb`
  - `bcm2712-rpi-cm5l-cm4io.dtb`
  - `bcm2712-rpi-cm5l-cm5io.dtb`
  - `bcm2712-rpi-5-b.dtb`
  - `bcm2712d0-rpi-5-b.dtb`
- System extension: `iscsi-tools v0.2.0`
- System extension: `util-linux-tools 2.41.2`
- Kernel arg: `module_blacklist=sdhci_brcmstb` (`-lite` variant only)

---

## After Booting

Talos enters **maintenance mode** waiting for a machine config:

```bash
# Generate config
talosctl gen config my-cluster https://<CONTROLPLANE_IP>:6443 \
  --additional-sans <CONTROLPLANE_IP>

# Apply to node
talosctl apply-config --insecure --nodes <NODE_IP> --file controlplane.yaml \
  --talosconfig talosconfig

# Bootstrap etcd (first control-plane node only)
talosctl bootstrap --nodes <CONTROLPLANE_IP> --talosconfig talosconfig

# Get kubeconfig
talosctl kubeconfig --nodes <CONTROLPLANE_IP> --talosconfig talosconfig
```

To upgrade an existing node, use the installer image matching your variant:

```bash
# CM5 Lite
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.5-lite

# CM5 with eMMC
talosctl upgrade --nodes <NODE_IP> --image ghcr.io/wheetazlab/talos-rpi-cm5-installer:v1.12.5-emmc
```

---

## References

**Talos / SBC**
- [Talos Linux docs — SBC support](https://www.talos.dev/v1.12/talos-guides/install/single-board-computers/)
- [sbc-raspberrypi releases](https://github.com/siderolabs/sbc-raspberrypi/releases)
- [NVMe boot patch (sbc-raspberrypi#81)](https://github.com/siderolabs/sbc-raspberrypi/issues/81)
- [CM5 boot issue fix (sbc-raspberrypi#79)](https://github.com/siderolabs/sbc-raspberrypi/pull/79)
- [Original boot issue (talos#12748)](https://github.com/siderolabs/talos/issues/12748)
- [Talos system extensions](https://www.talos.dev/v1.12/talos-guides/configuration/system-extensions/)
- [DeskPi Super6C](https://deskpi.com/products/deskpi-super6c-raspberry-pi-cm4-6-boards-cluster-mini-itx-board) — example CM4IO-compatible carrier board

**macb RP1 network fixes**
- [Network issues tracking issue (sbc-raspberrypi#82)](https://github.com/siderolabs/sbc-raspberrypi/issues/82) — upstream tracking issue
- [RPi downstream PCIe fix `359f37f`](https://github.com/raspberrypi/linux/commit/359f37f0faefb712add32a39f98751aea67d5c1f) — rpi-6.12.y (incompatible with 6.18 `tx_pending` semantics)
- [Mainline macb fix `bf9cf80`](https://github.com/torvalds/linux/commit/bf9cf80) — net: macb: Fix tx/rx malfunction after phy link down/up (not yet in 6.18.x stable)
- [Cadence GEM (macb) driver](https://elixir.bootlin.com/linux/v6.18.15/source/drivers/net/ethernet/cadence/macb_main.c) — `macb_start_xmit()` and `macb_tx_restart()` are the patched functions
- [rpi-6.18.y macb EEE PR #7270](https://github.com/raspberrypi/linux/pull/7270) — 4 EEE/LPI patches backported to our kernel build
- [BCM54213PE AutogrEEEn dispatch fix `f7576c7`](https://github.com/raspberrypi/linux/commit/f7576c7831a1) — PHY driver dispatch entry
- [BCM54213PE AutogrEEEn disable `89d02e4`](https://github.com/raspberrypi/linux/commit/89d02e4dc84a) — clears MII_BUF_CNTL_0 bit 0
