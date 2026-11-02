#!/usr/bin/env bash
# Prepare the pieces of the emulated router: the OpenWrt rootfs, its kernel
# and the WireGuard kernel modules.
#
# The layout of the target directory:
#
#   rootfs.img      the stock rootfs image
#   rootfs/         the extracted rootfs
#   kernel.bin      the kernel of the release
#   pkgs/           the kernel module packages
#
# The script is idempotent: everything it finds in place is left alone.
#
# Usage: fetch-guest.sh <target-dir>
set -euo pipefail

DEST=${1:?the target directory}
OW_REL=${OW_REL:-24.10.8}
BASE_URL=${BASE_URL:-https://downloads.openwrt.org}
OW_TARGET=$BASE_URL/releases/$OW_REL/targets/armsr/armv8
OW_IMG=openwrt-${OW_REL}-armsr-armv8-generic-ext4-rootfs.img
OW_KERNEL=openwrt-${OW_REL}-armsr-armv8-generic-kernel.bin

# The WireGuard kernel module and the crypto modules it needs are not part of
# the image, they come from the OpenWrt repository.
KMOD_PACKAGES=(
  kmod-wireguard
  kmod-crypto-lib-curve25519
  kmod-crypto-lib-chacha20poly1305
  kmod-crypto-lib-poly1305
  kmod-crypto-lib-chacha20
  kmod-crypto-kpp
  kmod-udptunnel4
  kmod-udptunnel6
)

SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

mkdir -p "$DEST/pkgs"
cd "$DEST"

if [ ! -d rootfs ]; then
  if [ ! -f rootfs.img ]; then
    echo "=== downloading the OpenWrt rootfs"
    curl -fsSL -O "$OW_TARGET/${OW_IMG}.gz"
    gunzip -f "${OW_IMG}.gz"
    mv -f "$OW_IMG" rootfs.img
  fi
  echo "=== extracting the rootfs"
  $SUDO mkdir -p rootfs
  $SUDO debugfs -R "rdump / $DEST/rootfs" rootfs.img >/dev/null 2>&1
  # debugfs extracts as root, and the guest is written to by the check.
  $SUDO chown -R "$(id -u):$(id -g)" rootfs
fi
[ -f kernel.bin ] || curl -fsSL -o kernel.bin "$OW_TARGET/$OW_KERNEL"

MODVER=$(ls rootfs/lib/modules | head -1)
echo "=== kernel modules for $MODVER"
KDIR=$(curl -fsSL "$OW_TARGET/kmods/" | grep -oE "href=\"$MODVER-[^\"]+/\"" | head -1 | cut -d'"' -f2 | tr -d /)
[ -n "$KDIR" ] || { echo "no kernel module directory for $MODVER" >&2; exit 1; }
INDEX=$OW_TARGET/kmods/$KDIR/Packages
INDEX_FILE=$DEST/pkgs/Packages
[ -f "$INDEX_FILE" ] || curl -fsSL -o "$INDEX_FILE" "$INDEX"
for pkg in "${KMOD_PACKAGES[@]}"; do
  file=$(awk -v p="$pkg" '$1 == "Package:" && $2 == p {hit = 1} hit && $1 == "Filename:" {print $2; exit}' "$INDEX_FILE")
  [ -n "$file" ] || { echo "package $pkg not found in $INDEX" >&2; exit 1; }
  [ -f "pkgs/$file" ] || curl -fsSL -o "pkgs/$file" "$OW_TARGET/kmods/$KDIR/$file"
done
ls -l pkgs
