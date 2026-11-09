#!/usr/bin/env bash
# Measure size, startup time and RAM usage of the packed binary inside a
# fully emulated arm64 guest.
#
# Why a guest and not a container: under qemu-user the call
# socket(AF_NETLINK, ..., NETLINK_GENERIC) returns EPROTONOSUPPORT, so
# wgctrl cannot be created and wg-portal panics on startup.
set -euo pipefail

QEMU=${QEMU:-qemu-system-aarch64}
VM=${VM:-/tmp/wgp-vm}
ALPINE_SERIES=${ALPINE_SERIES:-v3.21}
ALPINE_VER=${ALPINE_VER:-3.21.9}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-1800}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
DIST=${DIST:-$ROOT/dist}

mkdir -p "$VM"
cd "$VM"

[ -f vmlinuz-virt ] || curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -O \
  "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64/netboot/vmlinuz-virt"
[ -f "alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz" ] || curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors -O \
  "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64/alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"

echo "=== building the guest initramfs"
rm -rf root initramfs.gz
mkdir -p root
tar -xzf "alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz" -C root
mkdir -p root/proc root/sys root/dev root/tmp root/work
cp "$DIST/wg-portal.orig" "$DIST/wg-portal.packed" root/work/
cp "$HERE/bench-init.sh" root/init
cp "$HERE/bench-one.sh" root/work/bench-one.sh

chmod +x root/init root/work/bench-one.sh

( cd root && find . | cpio -o -H newc --quiet ) | gzip -1 > initramfs.gz
ls -l initramfs.gz

echo "=== booting $QEMU"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m 512 -nographic -no-reboot \
  -kernel vmlinuz-virt \
  -initrd initramfs.gz \
  -append "console=ttyAMA0 rdinit=/init init=/init quiet" \
  < /dev/null 2>&1 | tee console.log

echo "=== guest console saved to $VM/console.log"
