# Orbit Armbian image — B860H V2 (Amlogic)

A custom Armbian build for the **ZTE/Gongying B860H V2** TV box (Amlogic S905-class,
the `aml-s9xx-box` Armbian target), set up for the Orbit appliance:

- **Internal Wi-Fi as the primary network** — the onboard **Realtek RTL8189FS**
  (SDIO) driver is bundled as DKMS, Wi-Fi is unblocked at boot, managed by
  NetworkManager, preferred over Ethernet, and can be pre-seeded so the box joins a
  network on first boot.
- **USB-OTG (dwc2) gadget support for the Orbit goggles AOA link** — the gadget
  modules load at boot so the OTG port can act as a USB *device* (Android Open
  Accessory), the same mechanism orbit-rs uses on the Raspberry Pi. **Experimental**
  (see [AOA / USB-OTG](#aoa--usb-otg-experimental)).

> **Status:** build scaffolding, not a verified image. The Wi-Fi-primary setup is
> standard and safe. The AOA gadget part depends on board wiring and a device-tree
> setting that must be confirmed on real hardware — it is not known to work on the
> B860H yet.

This folder only holds the customisation. The actual build is done by
[Armbian's own build framework](https://github.com/armbian/build); `build.sh` drops
`userpatches/` into it and runs `compile.sh`.

## What's here

| File | Purpose |
|---|---|
| `build.sh` | Wrapper around Armbian `compile.sh` (board, branch, Wi-Fi pre-seed) |
| `userpatches/customize-image.sh` | Runs in the image chroot: Wi-Fi-primary, RTL8189FS driver, gadget modules |
| `userpatches/overlay/orbit-otg.sh` | On-box helper → `/usr/local/sbin/orbit-otg` (USB-OTG role) |
| `userpatches/overlay/orbit-wifi-driver.sh` | On-box helper → `/usr/local/sbin/orbit-wifi-driver` (build the Wi-Fi driver) |
| `userpatches/kernel-gadget.config` | Reference list of the kernel symbols the gadget needs |

`build.sh` also fetches the RTL8189FS driver source (`jwrdegoede/rtl8189ES_linux`,
branch `rtl8189fs`) into the Armbian overlay so it ships in the image. Skip it with
`WIFI_DRIVER=none`, or point elsewhere with `WIFI_DRIVER_REPO` / `WIFI_DRIVER_REF`.

## Requirements

- An **x86_64 Linux host with Docker** (Armbian builds in a container). Not macOS or
  arm64 — the Bootlin/Armbian toolchains have no build for those.
- ~30 GB free and a few hours for a first build.

## Build

```sh
# Armbian's build tree (cloned automatically if ARMBIAN_BUILD is unset):
git clone https://github.com/armbian/build ~/armbian-build

cd orbit-stream/armbian-b860h
ARMBIAN_BUILD=~/armbian-build ./build.sh

# Pre-seed Wi-Fi so the box joins on first boot (recommended — it's headless):
WIFI_SSID="MyNetwork" WIFI_PSK="secret" WIFI_COUNTRY=ID \
  ARMBIAN_BUILD=~/armbian-build ./build.sh
```

The image lands in `~/armbian-build/output/images/`. Write it to a microSD or USB
stick, boot the box from it, then (on Amlogic TV boxes) run the usual
`armbian-install` / `install-aml.sh` to move it to internal eMMC if you want.

### Options (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `ARMBIAN_BUILD` | `./build` | Path to an `armbian/build` checkout (cloned if missing) |
| `RELEASE` | `trixie` | Debian/Ubuntu userland |
| `BRANCH` | `current` | Kernel branch: `current` or `edge` |
| `KERNEL_CONFIGURE` | `no` | Set `yes` once if you need to flip the gadget Kconfig |
| `KERNEL_BTF` | `no` | Kernel BTF/eBPF info. Off by default — the LD/BTF step needs ~8 GB RAM. Set `yes` only on a big-RAM host that needs eBPF tooling. |
| `COMPRESS` | `sha,xz` | Output packaging. `sha,xz` makes a small `.img.xz` (like the official downloads); `sha,zstd` is faster; `sha,img` keeps the raw ~2 GB `.img`. |
| `WIFI_SSID` / `WIFI_PSK` | — | Pre-seed a Wi-Fi connection into the image |
| `WIFI_COUNTRY` | `ID` | Wi-Fi regulatory domain |

Extra arguments after `--` are passed straight to `compile.sh`, e.g.
`./build.sh -- DEB_COMPRESS=xz`.

## Picking the device tree (first boot)

`aml-s9xx-box` builds a *generic* Amlogic image; you choose the `.dtb` that matches
the box. For an S905X board this is usually `meson-gxl-s905x-p212.dtb` (or a
B860H-specific dtb if your Armbian tree ships one). Set it with `armbian-install`,
or edit `/boot/armbianEnv.txt`:

```
fdtfile=meson-gxl-s905x-p212.dtb
```

Confirm the SoC and the right dtb from the box's boot log before trusting this.

## Internal Wi-Fi (Realtek RTL8189FS)

The B860H V2's Wi-Fi is a **Realtek RTL8189FS** SDIO chip. Mainline `rtl8xxxu`
does not drive it, and the Amlogic `meson64` kernel dropped the in-tree `8189fs`
module after kernel 6.12.22, so the image bundles the out-of-tree driver
(`jwrdegoede/rtl8189ES_linux`, branch `rtl8189fs`) as **DKMS**: it builds for the
image's kernel and rebuilds itself on every future kernel upgrade.

`customize-image.sh` also makes NetworkManager manage every interface, unblocks the
radio at boot (`orbit-rfkill-unblock.service`), sets the regulatory domain, gives
Wi-Fi a lower route metric than Ethernet, and (with `WIFI_SSID`/`WIFI_PSK`) writes a
ready connection profile.

After first boot, check it came up:

```sh
orbit-wifi-driver status      # DKMS + module + interface
nmcli device status           # expect a 'wifi' device
```

**If the driver wasn't built in the image** (no kernel headers were available at
image time) or after a kernel upgrade, build it on the box:

```sh
orbit-wifi-driver             # installs headers, DKMS build+install, loads 8189fs
```

Two things to verify on hardware, since they depend on the chosen dtb:

- The driver's build profile is set to the generic arm64 (RPi) profile. If the DKMS
  build fails, adjust the platform flags in `/usr/src/rtl8189fs-*/Makefile`.
- The SDIO Wi-Fi node must be enabled in the device tree for the module to find the
  chip. If `8189fs` loads but no `wifi` device appears, the selected `.dtb` is
  missing/disabling the SDIO node — note it from `dmesg | grep -iE 'mmc|sdio'` and
  we can add an overlay.

## AOA / USB-OTG (experimental)

The Orbit goggles link needs the box to appear to the DJI goggles as a USB
*device* (Android Open Accessory). orbit-rs builds that gadget over configfs +
FunctionFS — exactly as on the Pi — **once the dwc2 OTG controller is in peripheral
mode and bound to a UDC.** This image provides the software side; the hardware side
has to be verified on the box.

What the image does:

- Loads `dwc2` and `libcomposite` at boot (`/etc/modules-load.d/orbit-aoa.conf`).
- Mounts configfs.
- Installs `orbit-otg` to inspect/switch the role.

What you must verify on the box (not doable from here):

1. **A UDC exists.** `orbit-otg status` — if `/sys/class/udc` is non-empty, the OTG
   port can be a gadget. If it's empty, the controller is stuck in host mode.
2. **`dr_mode` is `peripheral` or `otg`.** On Amlogic the dwc2 OTG node
   (`usb@ff400000`) usually ships as `dr_mode = "host"`. Device/gadget mode needs a
   device-tree change — a `.dtbo` overlay or a patched dtb setting
   `dr_mode = "peripheral"` (or `"otg"` with a working role-switch). This is
   board-specific and is the main unknown.
3. **Which physical port is the OTG one.** Many TV boxes route the USB-A ports
   through a host-only hub and expose OTG only on a separate pad/port (sometimes the
   one shared with power, or an internal header). The goggles must be on *that* port.

Kernel symbols the gadget needs are listed in `userpatches/kernel-gadget.config`.
The meson64 kernel usually already ships them as modules (for Android ADB), so a
kernel rebuild is often unnecessary — check on the box with
`zcat /proc/config.gz | grep -E 'DWC2|CONFIGFS|LIBCOMPOSITE|GADGET'`.

## Installing Orbit on the image

This repo builds the *platform* (kernel + Wi-Fi + gadget capability). The Orbit
services (orbit-rs / orbit-web / orbit-kms) are installed on top, as on the Debian
Pi: cross-build the Rust apps for `aarch64`, build orbit-kms against the image's
Mesa/FFmpeg, and install with the repo's `install.sh`. orbit-rs creates the AOA
gadget itself once the OTG port is in peripheral mode. That step is out of scope
here and is tracked separately.

## Known limits / open questions

- **AOA on Amlogic is unproven.** dwc2 peripheral mode on a B860H has not been
  confirmed; it may need a dtb/overlay change or may not be wired at all.
- **Wi-Fi driver builds in a qemu chroot at image time** and may fail there (missing
  headers); the on-box `orbit-wifi-driver` is the reliable fallback. The SDIO node
  must be present in the chosen dtb.
- The driver source is pinned to a moving branch (`rtl8189fs`), not a fixed commit.
- Generic Amlogic image: the correct `.dtb` must be chosen per box.
- Hardware video decode (for orbit-kms) on this SoC is a separate thing to validate,
  like on the ROCK 4 SE port.
