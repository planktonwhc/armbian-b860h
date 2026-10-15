#!/bin/bash
#
# Armbian runs this inside the image's chroot just before the image is packed.
# Commands here run for the target (arm64), not the build host. See
# https://docs.armbian.com/Developer-Guide_User-Configurations/
#
# It does two things for the B860H V2 (Amlogic) Orbit image:
#   1. Internal Wi-Fi as the primary network (NetworkManager, unblocked at
#      boot, optional pre-seeded connection from WIFI_SSID/WIFI_PSK).
#   2. Load the USB gadget modules at boot so the dwc2 OTG port can act as a
#      device for the Orbit goggles AOA link. (The port must also be in
#      peripheral/otg mode -- a device-tree setting, see README.)
#
set -euo pipefail

# Register the RTL8189FS driver with DKMS and try to build it for the kernel in
# this image. Non-fatal: if headers aren't in the chroot, the source stays in
# /usr/src and `orbit-wifi-driver` / `dkms autoinstall` build it on the box.
install_rtl8189fs() {
	local ver="git-$(date +%Y%m%d)"
	local src="/usr/src/rtl8189fs-${ver}"
	rm -rf "$src"
	cp -a /tmp/overlay/rtl8189fs "$src"

	# Build for ARM64. The driver's Makefile defaults to an x86 PC profile; the
	# RPi arm64 profile just sets ARCH=arm64 and suits generic arm64 boards.
	sed -i 's/^CONFIG_PLATFORM_I386_PC = y/CONFIG_PLATFORM_I386_PC = n/' "$src/Makefile" || true
	sed -i 's/^CONFIG_PLATFORM_ARM64_RPI = n/CONFIG_PLATFORM_ARM64_RPI = y/' "$src/Makefile" || true

	cat > "$src/dkms.conf" <<DKMS
PACKAGE_NAME="rtl8189fs"
PACKAGE_VERSION="${ver}"
BUILT_MODULE_NAME[0]="8189fs"
DEST_MODULE_LOCATION[0]="/kernel/drivers/net/wireless"
MAKE[0]="make ARCH=arm64 KVER=\${kernelver} KSRC=/lib/modules/\${kernelver}/build"
CLEAN="make clean"
AUTOINSTALL="yes"
DKMS

	apt-get -y install --no-install-recommends dkms build-essential bc || return 1
	# Headers for the just-built kernel (from Armbian's local repo). Branch/
	# family are in the image's kernel package name.
	apt-get -y install "linux-headers-$(uname -r)" 2>/dev/null \
		|| apt-get -y install 'linux-headers-current-meson64' 2>/dev/null || true

	dkms add -m rtl8189fs -v "$ver" || return 1
	local kver
	kver="$(ls /lib/modules 2>/dev/null | head -1)"
	if [ -n "$kver" ] && [ -d "/lib/modules/$kver/build" ]; then
		dkms build -m rtl8189fs -v "$ver" -k "$kver" \
			&& dkms install -m rtl8189fs -v "$ver" -k "$kver" \
			&& { depmod -a "$kver"; echo "orbit: RTL8189FS built and installed for $kver"; return 0; }
	fi
	echo "orbit: RTL8189FS registered with DKMS; no kernel headers here, will build on the box"
	return 0
}

Main() {
	# --- 1. Internal Wi-Fi, primary ------------------------------------------
	# NetworkManager owns all interfaces; make sure Wi-Fi is never soft-blocked
	# and has priority over Ethernet when both are up.
	mkdir -p /etc/NetworkManager/conf.d
	cat > /etc/NetworkManager/conf.d/10-orbit-wifi.conf <<'NM'
[main]
# Wi-Fi is the main link on this box; manage every device with NM.
[device]
wifi.scan-rand-mac-address=no
[connection]
# Prefer Wi-Fi over a plugged Ethernet cable (lower metric = higher priority).
ipv4.route-metric=100
NM

	# Unblock the radio on every boot (some boxes power up soft-blocked).
	cat > /etc/systemd/system/orbit-rfkill-unblock.service <<'UNIT'
[Unit]
Description=Unblock Wi-Fi radio at boot
Before=NetworkManager.service
[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
[Install]
WantedBy=multi-user.target
UNIT
	systemctl enable orbit-rfkill-unblock.service || true

	# Regulatory domain (channels/power). Default ID; overridden by WIFI_COUNTRY.
	local country="${WIFI_COUNTRY:-ID}"
	echo "REGDOMAIN=${country}" > /etc/default/crda 2>/dev/null || true
	mkdir -p /etc/modprobe.d
	echo "options cfg80211 ieee80211_regdom=${country}" > /etc/modprobe.d/orbit-regdom.conf

	# --- RTL8189FS SDIO Wi-Fi driver (the B860H V2's chip) -------------------
	# Mainline rtl8xxxu can't drive the 8189FS, and the meson64 kernel dropped
	# the in-tree module after 6.12.22, so install the out-of-tree driver as a
	# DKMS source: it builds now (if headers are available) and rebuilds itself
	# on every future kernel update. The on-box helper is the fallback.
	if [ "${WIFI_DRIVER:-rtl8189fs}" = "rtl8189fs" ] && [ -d /tmp/overlay/rtl8189fs ]; then
		install_rtl8189fs || echo "orbit: RTL8189FS driver not built in the image; build it on the box with 'orbit-wifi-driver' (see README)"
	fi

	# Optional: pre-seed a Wi-Fi connection so the box joins on first boot.
	if [ -n "${WIFI_SSID:-}" ]; then
		mkdir -p /etc/NetworkManager/system-connections
		local f="/etc/NetworkManager/system-connections/orbit-wifi.nmconnection"
		cat > "$f" <<NMCON
[connection]
id=orbit-wifi
type=wifi
autoconnect=true
autoconnect-priority=100
[wifi]
mode=infrastructure
ssid=${WIFI_SSID}
[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PSK:-}
[ipv4]
method=auto
[ipv6]
method=auto
NMCON
		chmod 600 "$f"
		echo "orbit: pre-seeded Wi-Fi connection for SSID '${WIFI_SSID}'"
	fi

	# --- 2. USB gadget (dwc2) for the Orbit goggles AOA link -----------------
	# Load the controller in peripheral mode and the composite gadget stack at
	# boot. dwc2 only comes up as a device if the OTG node's dr_mode is
	# peripheral/otg in the device tree (see README -- hardware-specific).
	cat > /etc/modules-load.d/orbit-aoa.conf <<'MOD'
# USB device-controller + gadget stack for the Orbit goggles AOA link.
dwc2
libcomposite
MOD

	# Load the Wi-Fi driver at boot (built above, or by orbit-wifi-driver later).
	echo "8189fs" > /etc/modules-load.d/orbit-wifi.conf

	# On-box helper to build/reinstall the Wi-Fi driver (DKMS) if the image
	# couldn't (no headers at image time, or after a kernel upgrade).
	if [ -f /tmp/overlay/orbit-wifi-driver.sh ]; then
		install -D -m 0755 /tmp/overlay/orbit-wifi-driver.sh /usr/local/sbin/orbit-wifi-driver
	fi

	# Put the OTG port in peripheral (device) mode at boot, so the goggles see
	# this box as a USB device for the AOA link -- like the Pi's dr_mode=peripheral.
	# The B860H exposes a runtime usb-role-switch (verified: role -> device, UDC
	# c9100000.usb), so no dtb change is needed. The '-' makes a board without a
	# role-switch boot cleanly. NOTE: this makes that USB port device-only; to use
	# it as a host instead, `systemctl disable --now orbit-otg-peripheral`.
	cat > /etc/systemd/system/orbit-otg-peripheral.service <<'UNIT'
[Unit]
Description=Put the USB-OTG port in peripheral mode for the Orbit goggles AOA link
After=multi-user.target
[Service]
Type=oneshot
ExecStart=-/usr/local/sbin/orbit-otg peripheral
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
	systemctl enable orbit-otg-peripheral.service || true

	# Make sure configfs is mounted (orbit-rs builds the gadget under it).
	if ! grep -q 'configfs' /etc/fstab; then
		echo "configfs /sys/kernel/config configfs defaults 0 0" >> /etc/fstab
	fi

	# Ship the OTG-port helper so it can be run on the box to check/switch roles.
	if [ -f /tmp/overlay/orbit-otg.sh ]; then
		install -D -m 0755 /tmp/overlay/orbit-otg.sh /usr/local/sbin/orbit-otg
	fi

	# --- B860H device tree (brings up the SDIO Wi-Fi bus) --------------------
	# The generic p212 reference dtb leaves the Wi-Fi SDIO bus off (no wlan0).
	# Install the B860H dtb and point extlinux at it. Verified at fetch time in
	# build.sh.
	if [ -f /tmp/overlay/meson-gxl-s905x-b860h.dtb ]; then
		install -D -m 0644 /tmp/overlay/meson-gxl-s905x-b860h.dtb \
			/boot/dtb/amlogic/meson-gxl-s905x-b860h.dtb
		if [ -f /boot/extlinux/extlinux.conf ]; then
			sed -i 's|^\([[:space:]]*\)fdt .*|\1fdt /dtb/amlogic/meson-gxl-s905x-b860h.dtb|' \
				/boot/extlinux/extlinux.conf
			echo "orbit: extlinux fdt -> B860H dtb"
		else
			echo "orbit: B860H dtb installed; set 'fdt /dtb/amlogic/meson-gxl-s905x-b860h.dtb' in extlinux.conf by hand (it was not present at image time)"
		fi
	fi

	echo "orbit: B860H image customised (Wi-Fi primary + dwc2 gadget modules)"
}

Main "$@"
