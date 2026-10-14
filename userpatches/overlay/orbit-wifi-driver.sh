#!/bin/bash
# orbit-wifi-driver -- build & install the RTL8189FS SDIO Wi-Fi driver on the
# box, via DKMS. Use this if the image shipped without the module built (no
# kernel headers at image time) or after a kernel upgrade.
#
#   orbit-wifi-driver            build + install for the running kernel, load it
#   orbit-wifi-driver status     show DKMS + module + interface state
#
set -euo pipefail

ver_dir="$(ls -d /usr/src/rtl8189fs-* 2>/dev/null | head -1 || true)"

status() {
	echo "== dkms =="; dkms status rtl8189fs 2>/dev/null || echo "  not registered"
	echo "== module =="; modinfo 8189fs 2>/dev/null | grep -E 'filename|version' || echo "  8189fs not installed"
	echo "== loaded =="; lsmod | grep -E '^8189fs' || echo "  not loaded"
	echo "== interface =="; nmcli device status 2>/dev/null | grep -i wifi || iw dev 2>/dev/null || echo "  no wifi device"
}

case "${1:-build}" in
	status) status ;;
	build)
		[ -n "$ver_dir" ] || { echo "driver source not found in /usr/src (rtl8189fs-*)" >&2; exit 1; }
		ver="${ver_dir##*/rtl8189fs-}"
		kver="$(uname -r)"
		[ -d "/lib/modules/$kver/build" ] || apt-get -y install "linux-headers-$kver" || {
			echo "install the kernel headers for $kver first (apt-get install linux-headers-current-meson64)"; exit 1; }
		dkms add -m rtl8189fs -v "$ver" 2>/dev/null || true
		dkms build -m rtl8189fs -v "$ver" -k "$kver"
		dkms install -m rtl8189fs -v "$ver" -k "$kver" --force
		depmod -a "$kver"
		modprobe 8189fs && echo "8189fs loaded" || echo "built, but modprobe failed -- check dmesg"
		;;
	*) echo "usage: orbit-wifi-driver [build|status]" >&2; exit 2 ;;
esac
