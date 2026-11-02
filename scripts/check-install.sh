#!/usr/bin/env bash
# Install the .ipk into the emulated router (a stock OpenWrt rootfs on a
# 128 MB flash with 512 MB of RAM) and start the installed binary.
#
# The guest is set up by Ansible, the same way the WireGuard check does it.
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
ANSIBLE_DIR=${ANSIBLE_DIR:-$ROOT/ansible}
ANSIBLE=${ANSIBLE:-ansible-playbook}

WEB_PORT=${WEB_PORT:-8888}
# The emulated router: 512 MB of RAM and 128 MB of flash.
MEM_MB=${MEM_MB:-512}
FLASH_MB=${FLASH_MB:-128}
# The link between the host and the guest.
TAP=${TAP:-tap-wg}
LINK_HOST=${LINK_HOST:-10.77.0.1}
LINK_GUEST=${LINK_GUEST:-10.77.0.2}

GUEST_ROOT=$VM/rootfs
PACKAGES=$VM/packages
KEY=$VM/id_ed25519
CONSOLE=$VM/console-opkg.log
FLASH=$VM/flash.img

# The script needs root for the tap device and the flash image. Inside the
# image it already is.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

cleanup() {
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  $SUDO ip link del "$TAP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$VM"
cd "$VM"

echo "=== fetching the OpenWrt guest"
"$HERE/vm/fetch-guest.sh" "$VM"

echo "=== preparing the guest for Ansible"
"$HERE/vm/bootstrap-guest.sh" "$GUEST_ROOT" "$KEY" "$LINK_GUEST"

echo "=== collecting the packages"
"$HERE/vm/collect-packages.sh" "$DIST" "$PACKAGES" "$VM/pkgs"

echo "=== building the flash of the router"
"$HERE/vm/build-flash.sh" "$GUEST_ROOT" "$FLASH" "$FLASH_MB"

echo "=== connecting the host and the guest with $TAP"
$SUDO ip link del "$TAP" 2>/dev/null || true
$SUDO ip tuntap add dev "$TAP" mode tap
$SUDO ip addr add "$LINK_HOST/24" dev "$TAP"
$SUDO ip link set "$TAP" up
# The offloads of the tap are not understood by the guest: with the checksum
# and segmentation offload on, the packets arrive broken.
$SUDO ethtool -K "$TAP" tso off gso off gro off tx off sg off 2>/dev/null || true

echo "=== booting $QEMU with the OpenWrt rootfs"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
  -kernel "$VM/kernel.bin" \
  -drive "file=$FLASH,format=raw,if=virtio" \
  -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0" \
  -netdev "tap,id=net0,ifname=$TAP,script=no,downscript=no" \
  -device virtio-net-pci,netdev=net0 \
  < /dev/null > "$CONSOLE" 2>&1 &
QEMU_PID=$!

cat > "$VM/vars.json" <<EOF
{
  "wgp_overrides": {
    "link_guest": "$LINK_GUEST",
    "web_port": $WEB_PORT,
    "key_file": "$KEY",
    "package_dir": "$PACKAGES"
  }
}
EOF

# Ansible needs the guest to be up: the boot of OpenWrt under the emulation
# takes a while, and a host that does not answer yet is "unreachable" for
# ansible, not "failed" — it does not retry.
echo "=== waiting for the guest"
i=0
until (exec 3<>/dev/tcp/"$LINK_GUEST"/22) 2>/dev/null; do
  kill -0 "$QEMU_PID" 2>/dev/null || { echo "the guest died:"; tail -30 "$CONSOLE"; exit 1; }
  sleep 2
  i=$((i + 1))
  [ $i -lt 300 ] || { echo "the guest did not come up"; tail -30 "$CONSOLE"; exit 1; }
done

echo "=== setting up the OpenWrt guest"
if ! "$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
     --tags setup -e @"$VM/vars.json"; then
  echo "the setup of the guest failed, the console of the router:" >&2
  tail -40 "$CONSOLE" >&2
  exit 1
fi

echo "=== checking the installation"
"$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
  --tags package -e @"$VM/vars.json"

echo "=== guest console saved to $CONSOLE"
