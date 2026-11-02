#!/usr/bin/env bash
# Build the flash of the emulated router: an ext4 filesystem with the OpenWrt
# rootfs in it.
#
# The router equivalent is 128 MB of flash and 512 MB of RAM. The image is
# attached as a virtio disk and the guest boots from it directly, so the
# rootfs lives on the flash and does not eat the RAM (as it would in an
# initramfs).
#
# Usage: build-flash.sh <rootfs-dir> <image> [size-mb]
set -euo pipefail

ROOTFS=${1:?the rootfs directory}
IMAGE=${2:?the image to create}
SIZE=${3:-128}

# Inside the image of the check the script runs as root already.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

$SUDO rm -f "$IMAGE"
$SUDO mke2fs -q -t ext4 -m 0 -b 4096 -F -d "$ROOTFS" -L routerflash "$IMAGE" "${SIZE}M"
# QEMU opens the image as the user, not as root.
$SUDO chown "$(id -u):$(id -g)" "$IMAGE"
ls -l "$IMAGE"
