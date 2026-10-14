#!/bin/bash
# orbit-otg -- inspect (and, where the controller allows it, switch) the USB
# OTG role on the B860H's dwc2 controller, for the Orbit goggles AOA link.
#
#   orbit-otg status       show the dwc2 node, its dr_mode and current role
#   orbit-otg peripheral   try to switch to device/peripheral at runtime
#   orbit-otg host         try to switch back to host
#
# Reliable role selection is a device-tree setting (dr_mode), not a runtime
# toggle on every board -- see the README. This helper just reports what the
# kernel exposes and uses the role-switch sysfs when it is present.
set -euo pipefail

dwc2_dir() {
	for d in /sys/bus/platform/drivers/dwc2/*; do
		[ -e "$d/mode" ] || [ -e "$d/../of_node/dr_mode" ] && { echo "$d"; return; }
	done
	return 1
}

role_switch() {
	# usb-role-switch exposes .../role = host|device|none on newer kernels.
	find /sys -name role -path '*usb*role*' 2>/dev/null | head -1
}

case "${1:-status}" in
	status)
		echo "== dwc2 platform devices =="
		ls -l /sys/bus/platform/drivers/dwc2/ 2>/dev/null || echo "  dwc2 driver not bound"
		for f in /sys/bus/platform/devices/*/mode; do
			[ -e "$f" ] && echo "mode($f) = $(cat "$f")"
		done
		rs="$(role_switch || true)"
		[ -n "$rs" ] && echo "role-switch: $rs = $(cat "$rs")" || echo "role-switch: none exposed"
		echo "udc: $(ls /sys/class/udc 2>/dev/null || echo none)  (a UDC here means the port can be a gadget)"
		;;
	peripheral|device)
		rs="$(role_switch || true)"
		[ -n "$rs" ] || { echo "no role-switch sysfs; set dr_mode=peripheral in the device tree instead (see README)"; exit 1; }
		echo device > "$rs"; echo "set $rs = device"
		;;
	host)
		rs="$(role_switch || true)"
		[ -n "$rs" ] || { echo "no role-switch sysfs on this board"; exit 1; }
		echo host > "$rs"; echo "set $rs = host"
		;;
	*) echo "usage: orbit-otg status|peripheral|host" >&2; exit 2 ;;
esac
