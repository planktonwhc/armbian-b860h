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
It likewise fetches the B860H device tree (checksum-pinned, `B860H_DTB=none` to
skip) — see [Device tree (required for Wi-Fi)](#device-tree-required-for-wi-fi).

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

### Device tree (required for Wi-Fi)

The generic `meson-gxl-s905x-p212.dtb` boots and gives Ethernet, but leaves the
**SDIO Wi-Fi bus off** — the driver loads but finds no chip, so there is no
`wlan0`. The build fetches a **B860H device tree** (`ZTE B860H`, based on p212,
which enables `sd_emmc_a` and the Wi-Fi power sequence), installs it to
`/boot/dtb/amlogic/meson-gxl-s905x-b860h.dtb`, and points `extlinux.conf` at it.
Verified on hardware: `wlan0` appears and the RTL8189FS (SDIO `024c:f179`) binds.

- Source: [hafidhh/B860H-HG680P-Armbian](https://github.com/hafidhh/B860H-HG680P-Armbian),
  pinned by SHA-256 (`B860H_DTB_SHA256`); skip with `B860H_DTB=none`.
- If you flashed an older image without this dtb, fix it live: copy that dtb into
  `/boot/dtb/amlogic/`, set the `fdt` line in `/boot/extlinux/extlinux.conf` to it,
  and reboot.

Other build-profile note: the driver's DKMS build uses the generic arm64 (RPi)
profile. If the build fails, adjust the platform flags in
`/usr/src/rtl8189fs-*/Makefile`.

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

Verified on the B860H: the box exposes a runtime **usb-role-switch** and a UDC
(`c9100000.usb`), and `orbit-otg peripheral` flips the role to `device` — so **no
dtb change is needed**. The image enables `orbit-otg-peripheral.service`, which
sets the port to device mode at every boot (like the Pi's `dr_mode=peripheral`).
This makes that USB port **device-only**; to use it as a host instead,
`systemctl disable --now orbit-otg-peripheral`.

Still to confirm with real goggles (needs orbit-rs, below):

1. **Which physical port is the OTG one.** Many TV boxes route the USB-A ports
   through a host-only hub and expose OTG only on one specific port (sometimes the
   one shared with power, or an internal header). The goggles must be on *that* port.
2. The full AOA handshake — only orbit-rs exercises it.

On another board that has no role-switch, `orbit-otg status` would show an empty
`/sys/class/udc`; there you'd need a device-tree `dr_mode = "peripheral"`/`"otg"`.

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
