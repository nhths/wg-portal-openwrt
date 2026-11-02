#!/usr/bin/env bash
# Install the .ipk into the emulated router (a stock OpenWrt rootfs on a
# 128 MB flash with 512 MB of RAM) and start the installed binary.
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
OW_TARGET=https://downloads.openwrt.org/releases/${OW_REL}/targets/armsr/armv8
OW_IMG=openwrt-${OW_REL}-armsr-armv8-generic-ext4-rootfs.img
OW_KERNEL=openwrt-${OW_REL}-armsr-armv8-generic-kernel.bin
# The emulated router: 512 MB of RAM and 128 MB of flash.
MEM_MB=${MEM_MB:-512}
FLASH_MB=${FLASH_MB:-128}
GUEST_ROOT=$VM/owroot

mkdir -p "$VM"
cd "$VM"

if [ ! -f "$OW_IMG" ]; then
  curl -fsSL -O "$OW_TARGET/${OW_IMG}.gz"
  gunzip -f "${OW_IMG}.gz"
fi
[ -f "$OW_KERNEL" ] || curl -fsSL -O "$OW_TARGET/$OW_KERNEL"

if [ ! -d "$GUEST_ROOT" ]; then
  sudo mkdir -p "$GUEST_ROOT"
  sudo debugfs -R "rdump / $GUEST_ROOT" "$OW_IMG" >/dev/null 2>&1
fi
# debugfs extracts as root and /init is a symlink to /sbin/init in the
# OpenWrt rootfs: drop it before writing our own.
sudo chown -R "$(id -u):$(id -g)" "$GUEST_ROOT"
sudo rm -f "$GUEST_ROOT/init"

IPK=$(ls "$DIST"/wg-portal_*.ipk 2>/dev/null | head -1 || true)
if [ -z "$IPK" ]; then
  echo "no .ipk in $DIST — run 'make dist' first" >&2
  exit 1
fi

echo "=== building the flash of the router"
cp "$IPK" "$GUEST_ROOT/tmp/wg-portal.ipk"
cp "$HERE/vm/guest-install.sh" "$GUEST_ROOT/init"
chmod +x "$GUEST_ROOT/init"
"$HERE/vm/build-flash.sh" "$GUEST_ROOT" "$VM/flash.img" "$FLASH_MB"

echo "=== booting $QEMU with the OpenWrt rootfs"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
  -kernel "$OW_KERNEL" \
  -drive "file=$VM/flash.img,format=raw,if=virtio" \
  -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0 init=/init" \
  < /dev/null 2>&1 | tee console-opkg.log

echo "=== guest console saved to $VM/console-opkg.log"
