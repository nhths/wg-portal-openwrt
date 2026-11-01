#!/usr/bin/env bash
# Install the .ipk into a stock OpenWrt rootfs running in a fully emulated
# arm64 guest and start the installed binary.
#
# The openwrt/rootfs container cannot be used for this: its opkg refuses to
# install local .ipk files at all, a genuine package from the OpenWrt
# repository fails the same way.
set -euo pipefail

VER=${VER:-v2.3.1}
ARCH=${ARCH:-aarch64_cortex-a53}
QEMU=${QEMU:-qemu-system-aarch64}
VM=${VM:-/tmp/wgp-vm}
OW_REL=${OW_REL:-24.10.8}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
DIST=${DIST:-$ROOT/dist}
OW_IMG=openwrt-${OW_REL}-armsr-armv8-generic-ext4-rootfs.img

mkdir -p "$VM"
cd "$VM"

if [ ! -f "$OW_IMG" ]; then
  curl -fsSL -O "https://downloads.openwrt.org/releases/${OW_REL}/targets/armsr/armv8/${OW_IMG}.gz"
  gunzip -f "${OW_IMG}.gz"
fi
[ -f vmlinuz-virt ] || curl -fsSL -O \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/netboot/vmlinuz-virt"

if [ ! -d owroot ]; then
  sudo mkdir -p owroot
  sudo debugfs -R "rdump / $VM/owroot" "$OW_IMG" >/dev/null 2>&1
fi
# debugfs extracts as root and /init is a symlink to /sbin/init in the
# OpenWrt rootfs: drop it before writing our own.
sudo chown -R "$(id -u):$(id -g)" owroot
sudo rm -f owroot/init

IPK=$(ls "$DIST"/wg-portal_*.ipk 2>/dev/null | head -1 || true)
if [ -z "$IPK" ]; then
  echo "no .ipk in $DIST — run 'make dist' first" >&2
  exit 1
fi

echo "=== building the guest initramfs"
rm -f initramfs-opkg.gz
cp "$IPK" owroot/tmp/wg-portal.ipk
cp "$HERE/vm/guest-install.sh" owroot/init
chmod +x owroot/init

( cd owroot && find . | cpio -o -H newc --quiet ) | gzip -1 > initramfs-opkg.gz
ls -l initramfs-opkg.gz

echo "=== booting $QEMU with the OpenWrt rootfs"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m 2048 -nographic -no-reboot \
  -kernel vmlinuz-virt \
  -initrd initramfs-opkg.gz \
  -append "console=ttyAMA0 rdinit=/init init=/init quiet" \
  < /dev/null 2>&1 | tee console-opkg.log

echo "=== guest console saved to $VM/console-opkg.log"
