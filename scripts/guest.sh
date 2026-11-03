#!/usr/bin/env bash
# The emulated router: the OpenWrt guest and the machine it runs on.
#
# One script, five steps:
#
#   fetch      download the rootfs, the kernel and the kernel modules
#   bootstrap  the key Ansible logs in with
#   packages   collect the .ipk of the portal and the kernel modules
#   flash      build the 128 MB flash of the router
#   boot       create the tap, start QEMU and wait for the guest
#
# The step is the first argument:
#
#   guest.sh fetch      <dir>
#   guest.sh bootstrap  <rootfs-dir> <key-file>
#   guest.sh packages   <dist-dir> <target-dir> <kernel-modules-dir>
#   guest.sh flash      <rootfs-dir> <image> [size-mb]
#   guest.sh boot       <flash-image> <kernel> <tap> <console> <pidfile>
set -euo pipefail

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

QEMU=${QEMU:-qemu-system-aarch64}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
MEM_MB=${MEM_MB:-512}
LINK_HOST=${LINK_HOST:-10.77.0.1}
LINK_GUEST=${LINK_GUEST:-10.77.0.2}

# The script needs root for the tap device, the flash image and the extraction
# of the rootfs. Inside the image of the check it already is.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# --- the pieces of the guest ---------------------------------------------------

fetch() {
  local dest=$1
  mkdir -p "$dest/pkgs"
  cd "$dest"

  if [ ! -d rootfs ]; then
    if [ ! -f rootfs.img ]; then
      echo "=== downloading the OpenWrt rootfs"
      curl -fsSL -O "$OW_TARGET/${OW_IMG}.gz"
      gunzip -f "${OW_IMG}.gz"
      mv -f "$OW_IMG" rootfs.img
    fi
    echo "=== extracting the rootfs"
    $SUDO mkdir -p rootfs
    $SUDO debugfs -R "rdump / $dest/rootfs" rootfs.img >/dev/null 2>&1
    # debugfs extracts as root, and the guest is written to by the check.
    $SUDO chown -R "$(id -u):$(id -g)" rootfs
  fi
  [ -f kernel.bin ] || curl -fsSL -o kernel.bin "$OW_TARGET/$OW_KERNEL"

  local modver kdir index pkg file
  modver=$(ls rootfs/lib/modules | head -1)
  echo "=== kernel modules for $modver"
  kdir=$(curl -fsSL "$OW_TARGET/kmods/" | grep -oE "href=\"$modver-[^\"]+/\"" | head -1 | cut -d'"' -f2 | tr -d /)
  [ -n "$kdir" ] || { echo "no kernel module directory for $modver" >&2; exit 1; }
  index=$OW_TARGET/kmods/$kdir/Packages
  [ -f pkgs/Packages ] || curl -fsSL -o pkgs/Packages "$index"
  for pkg in "${KMOD_PACKAGES[@]}"; do
    file=$(awk -v p="$pkg" '$1 == "Package:" && $2 == p {hit = 1} hit && $1 == "Filename:" {print $2; exit}' pkgs/Packages)
    [ -n "$file" ] || { echo "package $pkg not found in $index" >&2; exit 1; }
    [ -f "pkgs/$file" ] || curl -fsSL -o "pkgs/$file" "$OW_TARGET/kmods/$kdir/$file"
  done
  ls -l pkgs
}

# --- the guest for Ansible ------------------------------------------------------

# The setup of the guest is done by Ansible over SSH, so the guest has to be
# reachable before Ansible can start. The key Ansible logs in with is baked
# into the flash for that; the network of the guest is written into the
# rootfs by the play (templates/openwrt/network.j2), because it has to be in
# the flash before the router boots.
bootstrap() {
  local rootfs=$1 key=$2

  if [ ! -f "$key" ]; then
    echo "=== generating the key Ansible logs in with"
    ssh-keygen -t ed25519 -N '' -f "$key" -q
  fi

  mkdir -p "$rootfs/etc/dropbear"
  cp "$key.pub" "$rootfs/etc/dropbear/authorized_keys"
  chmod 600 "$rootfs/etc/dropbear/authorized_keys"
}

# --- the packages of the guest ---------------------------------------------------

packages() {
  local dist=$1 target=$2 kmods=$3

  mkdir -p "$target"

  local ipk pkg file
  ipk=$(ls "$dist"/wg-portal_*.ipk 2>/dev/null | head -1)
  [ -n "$ipk" ] || { echo "no .ipk in $dist — run 'make dist' first" >&2; exit 1; }
  cp "$ipk" "$target/wg-portal.ipk"

  for pkg in "${KMOD_PACKAGES[@]}"; do
    file=$(ls "$kmods/$pkg"_*.ipk 2>/dev/null | head -1)
    [ -n "$file" ] || { echo "the package $pkg is missing in $kmods" >&2; exit 1; }
    cp "$file" "$target/$pkg.ipk"
  done

  ls -l "$target"
}

# --- the flash of the router ------------------------------------------------------

# The router equivalent is 128 MB of flash and 512 MB of RAM. The image is
# attached as a virtio disk and the guest boots from it directly, so the rootfs
# lives on the flash and does not eat the RAM (as it would in an initramfs).
flash() {
  local rootfs=$1 image=$2 size=${3:-128}

  $SUDO rm -f "$image"
  $SUDO mke2fs -q -t ext4 -m 0 -b 4096 -F -d "$rootfs" -L routerflash "$image" "${size}M"
  # QEMU opens the image as the user, not as root.
  $SUDO chown "$(id -u):$(id -g)" "$image"
  ls -l "$image"
}

# --- the router ---------------------------------------------------------------------

# The host and the guest are connected by a tap device, not by the user-mode
# network of QEMU: slirp rewrites the UDP endpoints of the forwarded ports, and
# a WireGuard peer only accepts the handshake response from the address it sent
# the request to. Over a tap the endpoint of the client stays the same in both
# directions.
boot() {
  local image=$1 kernel=$2 tap=$3 console=$4 pidfile=$5

  echo "=== connecting the host and the guest with $tap"
  $SUDO ip link del "$tap" 2>/dev/null || true
  $SUDO ip tuntap add dev "$tap" mode tap
  $SUDO ip addr add "$LINK_HOST/24" dev "$tap"
  $SUDO ip link set "$tap" up
  # The offloads of the tap are not understood by the guest: with the checksum
  # and segmentation offload on, the packets arrive broken.
  $SUDO ethtool -K "$tap" tso off gso off gro off tx off sg off 2>/dev/null || true

  echo "=== booting $QEMU with the OpenWrt rootfs"
  timeout "$BOOT_TIMEOUT" "$QEMU" \
    -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
    -kernel "$kernel" \
    -drive "file=$image,format=raw,if=virtio" \
    -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0" \
    -netdev "tap,id=net0,ifname=$tap,script=no,downscript=no" \
    -device virtio-net-pci,netdev=net0 \
    < /dev/null > "$console" 2>&1 &
  echo $! > "$pidfile"

  # Ansible needs the guest to be up: the boot of OpenWrt under the emulation
  # takes a while, and a host that does not answer yet is "unreachable" for
  # ansible, not "failed" — it does not retry.
  echo "=== waiting for the guest"
  local i=0
  until (exec 3<>/dev/tcp/"$LINK_GUEST"/22) 2>/dev/null; do
    kill -0 "$(cat "$pidfile")" 2>/dev/null || { echo "the guest died:"; tail -30 "$console"; exit 1; }
    sleep 2
    i=$((i + 1))
    [ $i -lt 300 ] || { echo "the guest did not come up"; tail -30 "$console"; exit 1; }
  done
}

# --- the dispatcher --------------------------------------------------------------------

case "${1:-}" in
  fetch) fetch "${2:?the target directory}" ;;
  bootstrap) bootstrap "${2:?the rootfs directory}" "${3:?the key file}" ;;
  packages) packages "${2:?the directory with the .ipk of the portal}" "${3:?the target directory}" "${4:?the directory with the kernel module packages}" ;;
  flash) flash "${2:?the rootfs directory}" "${3:?the image to create}" "${4:-128}" ;;
  boot) boot "${2:?the flash image}" "${3:?the kernel}" "${4:?the tap device}" "${5:?the console file}" "${6:?the pid file}" ;;
  *)
    echo "usage: $0 {fetch|bootstrap|packages|flash|boot} ..." >&2
    exit 2
    ;;
esac
