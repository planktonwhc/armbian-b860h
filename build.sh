#!/usr/bin/env bash
#
# build.sh -- build a custom Armbian image for the B860H V2 (Amlogic) TV box,
# with the internal Wi-Fi as the primary network and the USB-OTG controller
# (dwc2) able to act as a gadget, for the Orbit goggles AOA link.
#
# It is a thin wrapper around Armbian's own `compile.sh`: it drops this folder's
# `userpatches/` into the Armbian build tree and runs the build with the right
# board/branch. Everything board-specific lives in userpatches/ so it survives
# an Armbian update.
#
# Needs an x86_64 Linux host with Docker (Armbian builds in a container). Not
# macOS / arm64. A first build downloads a lot and takes a few hours.
#
# Quick start:
#   git clone https://github.com/armbian/build ~/armbian-build
#   ARMBIAN_BUILD=~/armbian-build ./build.sh
#   # Wi-Fi can be pre-seeded so the box joins on first boot:
#   WIFI_SSID="MyNet" WIFI_PSK="secret" ARMBIAN_BUILD=~/armbian-build ./build.sh
#
# Options are environment variables (all optional):
#   ARMBIAN_BUILD   path to an armbian/build checkout (default: ./build, cloned if missing)
#   RELEASE         Debian/Ubuntu release (default: trixie)
#   BRANCH          kernel branch: current | edge (default: current)
#   KERNEL_CONFIGURE yes | no (default: no; set yes once to flip the gadget Kconfig)
#   WIFI_SSID/WIFI_PSK  pre-seed a Wi-Fi connection into the image
#   WIFI_COUNTRY    regulatory domain for Wi-Fi (default: ID)
#   WIFI_DRIVER     rtl8189fs (default) or none -- bundle the out-of-tree
#                   RTL8189FS SDIO driver (the B860H V2's Wi-Fi chip) as DKMS
#   WIFI_DRIVER_REPO / WIFI_DRIVER_REF  override the driver source/branch
# Extra args after `--` go straight to compile.sh.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOARD="aml-s9xx-box"
RELEASE="${RELEASE:-trixie}"
BRANCH="${BRANCH:-current}"
KERNEL_CONFIGURE="${KERNEL_CONFIGURE:-no}"
ARMBIAN_BUILD="${ARMBIAN_BUILD:-$HERE/build}"

EXTRA=()
if [ "${1:-}" = "--" ]; then shift; EXTRA=("$@"); fi

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) : ;;
  *) die "Armbian builds only on an x86_64 Linux host (Docker). This is $(uname -s)/$(uname -m)." ;;
esac

if [ ! -d "$ARMBIAN_BUILD/.git" ]; then
  say "Cloning armbian/build into $ARMBIAN_BUILD"
  git clone --depth=1 https://github.com/armbian/build "$ARMBIAN_BUILD"
fi

say "Syncing userpatches into the Armbian tree"
mkdir -p "$ARMBIAN_BUILD/userpatches"
# Copy our customisation in; never delete the user's other userpatches.
cp -av "$HERE/userpatches/." "$ARMBIAN_BUILD/userpatches/"

# The B860H V2's Wi-Fi is a Realtek RTL8189FS (SDIO). Mainline rtl8xxxu does not
# drive it, and the meson64 kernel dropped the in-tree module after 6.12.22, so
# bundle the out-of-tree driver as a DKMS source. It lands in the chroot at
# /tmp/overlay/rtl8189fs; customize-image.sh registers and builds it.
WIFI_DRIVER="${WIFI_DRIVER:-rtl8189fs}"
if [ "$WIFI_DRIVER" = "rtl8189fs" ]; then
  repo="${WIFI_DRIVER_REPO:-https://github.com/jwrdegoede/rtl8189ES_linux}"
  ref="${WIFI_DRIVER_REF:-rtl8189fs}"
  dst="$ARMBIAN_BUILD/userpatches/overlay/rtl8189fs"
  if [ ! -d "$dst/.git" ]; then
    say "Fetching RTL8189FS driver ($repo @ $ref)"
    rm -rf "$dst"
    git clone --depth=1 --branch "$ref" "$repo" "$dst"
  else
    echo "  using existing driver clone at $dst"
  fi
  rm -rf "$dst/.git"   # don't ship the git history into the image
elif [ "$WIFI_DRIVER" != "none" ]; then
  die "WIFI_DRIVER must be 'rtl8189fs' or 'none' (got '$WIFI_DRIVER')"
fi
export WIFI_DRIVER

# Wi-Fi pre-seed and country are read by customize-image.sh from the environment.
export WIFI_SSID="${WIFI_SSID:-}" WIFI_PSK="${WIFI_PSK:-}" WIFI_COUNTRY="${WIFI_COUNTRY:-ID}"

say "Building Armbian ($BOARD, $RELEASE, $BRANCH)"
cd "$ARMBIAN_BUILD"
exec ./compile.sh \
  BOARD="$BOARD" \
  BRANCH="$BRANCH" \
  RELEASE="$RELEASE" \
  BUILD_DESKTOP=no \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE="$KERNEL_CONFIGURE" \
  "${EXTRA[@]}"
