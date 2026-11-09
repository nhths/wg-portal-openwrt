#!/usr/bin/env bash
# The emulated router: the OpenWrt guest and the machine it runs on.
#
#   guest.sh fetch      <dir>
#   guest.sh bootstrap  <rootfs-dir> <key-file>
#   guest.sh packages   <dist-dir> <target-dir> <kernel-modules-dir> <feed-dir>
#   guest.sh flash      <rootfs-dir> <image> [size-mb]
#   guest.sh boot       <flash-image> <kernel> <tap> <console> <pidfile>
set -euo pipefail

OW_REL=${OW_REL:-25.12.6}
BASE_URL=${BASE_URL:-https://downloads.openwrt.org}
OW_TARGET=$BASE_URL/releases/$OW_REL/targets/armsr/armv8
OW_IMG=openwrt-${OW_REL}-armsr-armv8-generic-ext4-rootfs.img
OW_KERNEL=openwrt-${OW_REL}-armsr-armv8-generic-kernel.bin

# The WireGuard kernel module and the crypto modules it needs are not part of
# the image, they come from the OpenWrt repository. The name of a package of
# apk v3 is its name and its version: kmod-wireguard-6.12.112-r1.apk.
KMOD_PACKAGES=(
  kmod-wireguard
  kmod-crypto-lib-curve25519
  kmod-crypto-lib-chacha20poly1305
  kmod-crypto-lib-poly1305
  kmod-crypto-lib-chacha20
  kmod-crypto-hash
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

# The download of a file: HTTP/1.1 (the streams of HTTP/2 are reset by the
# mirrors from time to time), with retries, and resumed from where it stopped
# — a file that is fetched over a long line gets cut in the middle.
curl_get() {
  local url=$1 dest=$2
  curl -fsSL --http1.1 --retry 5 --retry-all-errors --retry-delay 2 \
    -C - -o "$dest" "$url"
}

fetch() {
  local dest=$1
  mkdir -p "$dest/pkgs"
  cd "$dest"

  if [ ! -d rootfs ]; then
    if [ ! -f rootfs.img ]; then
      echo "=== downloading the OpenWrt rootfs"
      curl_get "$OW_TARGET/${OW_IMG}.gz" "${OW_IMG}.gz"
      gunzip -f "${OW_IMG}.gz"
      mv -f "$OW_IMG" rootfs.img
    fi
    echo "=== extracting the rootfs"
    $SUDO mkdir -p rootfs
    $SUDO debugfs -R "rdump / $dest/rootfs" rootfs.img >/dev/null 2>&1
    # debugfs extracts as root, and the guest is written to by the check.
    $SUDO chown -R "$(id -u):$(id -g)" rootfs
  fi
  [ -f kernel.bin ] || curl_get "$OW_TARGET/$OW_KERNEL" kernel.bin

  local modver kdir index pkg file version
  modver=$(ls rootfs/lib/modules | head -1)
  echo "=== kernel modules for $modver"
  kdir=$(curl -fsSL "$OW_TARGET/kmods/" | grep -oE "href=\"$modver-[^\"]+/\"" | head -1 | cut -d'"' -f2 | tr -d /)
  [ -n "$kdir" ] || { echo "no kernel module directory for $modver" >&2; exit 1; }
  index=$OW_TARGET/kmods/$kdir

  # The index of the feed of the modules is signed with the key of the
  # firmware, and the guest trusts that key out of the box.
  [ -f pkgs/packages.adb ] || curl_get "$index/packages.adb" pkgs/packages.adb
  [ -f pkgs/index.json ] || curl_get "$index/index.json" pkgs/index.json

  for pkg in "${KMOD_PACKAGES[@]}"; do
    version=$(grep -o "\"$pkg\": \"[^\"]*\"" pkgs/index.json | head -1 | sed 's/.*: "\(.*\)"/\1/')
    [ -n "$version" ] || { echo "package $pkg not found in $index" >&2; exit 1; }
    file=$pkg-$version.apk
    [ -f "pkgs/$file" ] || curl_get "$index/$file" "pkgs/$file"
  done
  ls -l pkgs
}

# --- the guest for Ansible ------------------------------------------------------

# The network of the guest is written into the rootfs by the play
# (templates/openwrt/network.j2): it has to be in the flash before the router
# boots, because Ansible needs SSH to get into the guest at all.
bootstrap() {
  local rootfs=$1 key=$2

  if [ ! -f "$key" ]; then
    echo "=== generating the key Ansible logs in with"
    ssh-keygen -t ed25519 -N '' -f "$key" -q
  fi

  mkdir -p "$rootfs/etc/dropbear"
  # A file left over by a run as root is not writable by the user of the
  # host, and the copy over it fails.
  rm -f "$rootfs/etc/dropbear/authorized_keys"
  cp "$key.pub" "$rootfs/etc/dropbear/authorized_keys"
  chmod 600 "$rootfs/etc/dropbear/authorized_keys"
}

# --- the packages of the guest ---------------------------------------------------

# The feed of the kernel modules and the feed of the portal. apk knows no
# file:// url, so the feeds are served over HTTP by the host: the guest
# fetches the index and the packages from them. The url of a feed is the url
# of its index — a url that ends with ".adb" is taken as it is, and the
# packages of the feed are taken from the same directory by their name.
packages() {
  local dist=$1 kmods=$2 feed=$3 wgpfeed=$4

  mkdir -p "$feed" "$wgpfeed"
  # A directory left over by a run as root is not writable by the user of
  # the host, and the copies into it fail.
  $SUDO chown -R "$(id -u):$(id -g)" "$feed" "$wgpfeed"

  local apk pkg file
  apk=$(ls "$dist"/wg-portal-*.apk 2>/dev/null | head -1)
  [ -n "$apk" ] || { echo "no .apk in $dist — run 'make dist' first" >&2; exit 1; }
  cp "$apk" "$wgpfeed/"
  [ -f "$dist/packages.adb" ] || { echo "no index in $dist — run 'make feed' first" >&2; exit 1; }
  cp "$dist/packages.adb" "$wgpfeed/packages.adb"

  for pkg in "${KMOD_PACKAGES[@]}"; do
    # The name of a package of apk v3 is its name and its version:
    # kmod-wireguard-6.12.112-r1.apk
    file=$(ls "$kmods/$pkg"-*.apk 2>/dev/null | head -1)
    [ -n "$file" ] || { echo "the package $pkg is missing in $kmods" >&2; exit 1; }
    cp "$file" "$feed/"
  done

  cp "$kmods/packages.adb" "$feed/packages.adb"

  ls -l "$feed" "$wgpfeed"
}

# --- the flash of the router ------------------------------------------------------

# The rootfs lives on the flash and does not eat the RAM (as it would in an
# initramfs).
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
  # A console or a pid file left over by a run as root is not writable by
  # the user of the host, and the boot fails on them.
  rm -f "$console" "$pidfile"
  timeout "$BOOT_TIMEOUT" "$QEMU" \
    -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
    -kernel "$kernel" \
    -drive "file=$image,format=raw,if=virtio" \
    -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0" \
    -netdev "tap,id=net0,ifname=$tap,script=no,downscript=no" \
    -device virtio-net-pci,netdev=net0 \
    < /dev/null > "$console" 2>&1 &
  echo $! > "$pidfile"

  # A host that does not answer yet is "unreachable" for ansible, not
  # "failed" — it does not retry. So the boot is waited for here.
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
  packages) packages "${2:?the directory with the .apk of the portal}" "${3:?the directory with the kernel module packages}" "${4:?the directory of the feed of the modules}" "${5:?the directory of the feed of the portal}" ;;
  flash) flash "${2:?the rootfs directory}" "${3:?the image to create}" "${4:-128}" ;;
  boot) boot "${2:?the flash image}" "${3:?the kernel}" "${4:?the tap device}" "${5:?the console file}" "${6:?the pid file}" ;;
  *)
    echo "usage: $0 {fetch|bootstrap|packages|flash|boot} ..." >&2
    exit 2
    ;;
esac
