#!/usr/bin/env bash
# End-to-end WireGuard check.
#
# The packaged wg-portal runs in an emulated OpenWrt guest and manages a real
# WireGuard server interface. A client on the host uses the configuration the
# portal hands out and pings through the tunnel.
#
# The two are connected by a tap device, not by the user-mode network of QEMU:
# slirp rewrites the UDP endpoints of the forwarded ports, and a WireGuard
# peer only accepts the handshake response from the address it sent the
# request to. Over a tap the endpoint of the client stays the same in both
# directions.
set -euo pipefail

QEMU=${QEMU:-qemu-system-aarch64}
VM=${VM:-/tmp/wgp-vm}
OW_REL=${OW_REL:-24.10.8}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-900}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
DIST=${DIST:-$ROOT/dist}
BASE_URL=${BASE_URL:-https://downloads.openwrt.org}

WEB_PORT=${WEB_PORT:-8888}
WG_PORT=${WG_PORT:-51820}
SERVER_ADDR=${SERVER_ADDR:-10.99.0.1}
CLIENT_ADDR=${CLIENT_ADDR:-10.99.0.2}
SUBNET=${SUBNET:-10.99.0.0/24}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-wg-portal-check-password}
CLIENT_IF=${CLIENT_IF:-wg-test}
# The emulated router: 512 MB of RAM and 128 MB of flash.
MEM_MB=${MEM_MB:-512}
FLASH_MB=${FLASH_MB:-128}
# The link between the host and the guest.
TAP=${TAP:-tap-wg}
LINK_HOST=${LINK_HOST:-10.77.0.1}
LINK_GUEST=${LINK_GUEST:-10.77.0.2}
LINK_NET=${LINK_NET:-10.77.0.0/24}

OW_TARGET=$BASE_URL/releases/$OW_REL/targets/armsr/armv8
OW_IMG=openwrt-${OW_REL}-armsr-armv8-generic-ext4-rootfs.img
OW_KERNEL=openwrt-${OW_REL}-armsr-armv8-generic-kernel.bin
DL=$VM/pkgs
GUEST_ROOT=$VM/owwg
CONSOLE=$VM/console-wg.log

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

cleanup() {
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  sudo ip link del "$CLIENT_IF" 2>/dev/null || true
  sudo ip link del "$TAP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$VM" "$DL"
cd "$VM"

# --- the image, the kernel and the kernel modules ---------------------------

if [ ! -f "$OW_IMG" ]; then
  echo "=== downloading the OpenWrt rootfs"
  curl -fsSL -O "$OW_TARGET/${OW_IMG}.gz"
  gunzip -f "${OW_IMG}.gz"
fi
[ -f "$OW_KERNEL" ] || curl -fsSL -O "$OW_TARGET/$OW_KERNEL"

if [ ! -d "$GUEST_ROOT" ]; then
  echo "=== extracting the rootfs"
  sudo mkdir -p "$GUEST_ROOT"
  sudo debugfs -R "rdump / $GUEST_ROOT" "$OW_IMG" >/dev/null 2>&1
fi
# debugfs extracts as root and /init is a symlink to /sbin/init in the
# OpenWrt rootfs: drop it before writing our own.
sudo chown -R "$(id -u):$(id -g)" "$GUEST_ROOT"
sudo rm -f "$GUEST_ROOT/init"

MODVER=$(ls "$GUEST_ROOT/lib/modules" | head -1)
echo "=== kernel modules for $MODVER"
KDIR=$(curl -fsSL "$OW_TARGET/kmods/" | grep -oE "href=\"$MODVER-[^\"]+/\"" | head -1 | cut -d'"' -f2 | tr -d /)
[ -n "$KDIR" ] || { echo "no kernel module directory for $MODVER" >&2; exit 1; }
INDEX=$OW_TARGET/kmods/$KDIR/Packages
INDEX_FILE=$VM/kmods-Packages
[ -f "$INDEX_FILE" ] || curl -fsSL -o "$INDEX_FILE" "$INDEX"
for pkg in "${KMOD_PACKAGES[@]}"; do
  file=$(awk -v p="$pkg" '$1 == "Package:" && $2 == p {hit = 1} hit && $1 == "Filename:" {print $2; exit}' "$INDEX_FILE")
  [ -n "$file" ] || { echo "package $pkg not found in $INDEX" >&2; exit 1; }
  if [ ! -f "$DL/$file" ]; then
    curl -fsSL -o "$DL/$file" "$OW_TARGET/kmods/$KDIR/$file"
  fi
done
ls -l "$DL"

# --- the guest ---------------------------------------------------------------

IPK=$(ls "$DIST"/wg-portal_*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || { echo "no .ipk in $DIST — run 'make dist' first" >&2; exit 1; }

echo "=== building the flash of the router"
cp "$IPK" "$GUEST_ROOT/tmp/wg-portal.ipk"
cp "$DL"/kmod-*.ipk "$GUEST_ROOT/tmp/"
cp "$HERE/vm/guest-wireguard.sh" "$GUEST_ROOT/init"
chmod +x "$GUEST_ROOT/init"
printf 'LINK_ADDR=%s/%s\nCLIENT_ADDR=%s\n' "$LINK_GUEST" "${LINK_NET#*/}" "$CLIENT_ADDR" \
  > "$GUEST_ROOT/tmp/net.conf"
"$HERE/vm/build-flash.sh" "$GUEST_ROOT" "$VM/flash.img" "$FLASH_MB"

echo "=== connecting the host and the guest with $TAP"
sudo ip link del "$TAP" 2>/dev/null || true
sudo ip tuntap add dev "$TAP" mode tap
sudo ip addr add "$LINK_HOST/24" dev "$TAP"
sudo ip link set "$TAP" up
# The offloads of the tap are not understood by the guest: with the checksum
# and segmentation offload on, the packets arrive broken.
sudo ethtool -K "$TAP" tso off gso off gro off tx off sg off 2>/dev/null || true

echo "=== booting $QEMU"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
  -kernel "$OW_KERNEL" \
  -drive "file=$VM/flash.img,format=raw,if=virtio" \
  -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0 init=/init" \
  -netdev "tap,id=net0,ifname=$TAP,script=no,downscript=no" \
  -device virtio-net-pci,netdev=net0 \
  < /dev/null > "$CONSOLE" 2>&1 &
QEMU_PID=$!

echo "=== waiting for the portal"
i=0
until curl -fsS -o /dev/null "http://$LINK_GUEST:$WEB_PORT/api/v0/auth/providers"; do
  kill -0 "$QEMU_PID" 2>/dev/null || { echo "the guest died:"; tail -30 "$CONSOLE"; exit 1; }
  sleep 2
  i=$((i + 1))
  [ $i -lt 150 ] || { echo "the portal did not come up"; tail -30 "$CONSOLE"; exit 1; }
done
echo "the portal is up"

# --- the interface and the peer, through the API -----------------------------

echo "=== creating the interface and the peer"
python3 "$HERE/portal-api.py" \
  --base "http://$LINK_GUEST:$WEB_PORT" \
  --password "$ADMIN_PASSWORD" \
  --interface wg0 \
  --listen-port "$WG_PORT" \
  --address "$SERVER_ADDR/24" \
  --peer-address "$CLIENT_ADDR/32" \
  --peer-allowed-ips "$SUBNET" \
  > "$VM/peer.conf"
cat "$VM/peer.conf"

PRIVKEY=$(sed -n 's/^PrivateKey = //p' "$VM/peer.conf")
SERVERKEY=$(sed -n 's/^PublicKey = //p' "$VM/peer.conf")
PSK=$(sed -n 's/^PresharedKey = //p' "$VM/peer.conf")
CLIENT_IPS=$(sed -n 's/^AllowedIPs = //p' "$VM/peer.conf")
[ -n "$PRIVKEY" ] && [ -n "$SERVERKEY" ] || { echo "no keys in the peer config" >&2; exit 1; }

# --- the client on the host --------------------------------------------------

echo "=== bringing up the client"
KEYFILE=$(mktemp)
PSKFILE=$(mktemp)
chmod 600 "$KEYFILE" "$PSKFILE"
printf '%s\n' "$PRIVKEY" > "$KEYFILE"
printf '%s\n' "$PSK" > "$PSKFILE"

sudo ip link del "$CLIENT_IF" 2>/dev/null || true
sudo ip link add "$CLIENT_IF" type wireguard
sudo ip addr add "$CLIENT_ADDR/32" dev "$CLIENT_IF"
sudo wg set "$CLIENT_IF" private-key "$KEYFILE" \
  peer "$SERVERKEY" preshared-key "$PSKFILE" \
  allowed-ips "$CLIENT_IPS" endpoint "$LINK_GUEST:$WG_PORT" \
  persistent-keepalive 25
sudo ip link set "$CLIENT_IF" up
# The kernel does not route the allowed IPs of a peer on its own, the route to
# the server network has to go into the tunnel explicitly.
sudo ip route add "$CLIENT_IPS" dev "$CLIENT_IF"
rm -f "$KEYFILE" "$PSKFILE"

echo "=== pinging through the tunnel"
sleep 2
if ping -c 3 -W 3 -I "$CLIENT_IF" "$SERVER_ADDR"; then
  PING_OK=1
else
  PING_OK=0
fi

# The guest pings the client through the tunnel as well, wait for its verdict.
echo "=== waiting for the guest to ping through the tunnel"
i=0
until grep -q "TUNNEL_PING=" "$CONSOLE"; do
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 2
  i=$((i + 1))
  [ $i -lt 60 ] || break
done
GUEST_PING=$(grep -o "TUNNEL_PING=[A-Z]*" "$CONSOLE" | tail -1)

echo "=== client state"
sudo wg show "$CLIENT_IF"

echo "=== guest console"
grep -E "PORTAL_READY|TUNNEL_TRAFFIC|TUNNEL_PING|=== " "$CONSOLE" | tail -25

if [ "$PING_OK" = 1 ] && [ "$GUEST_PING" = "TUNNEL_PING=OK" ]; then
  echo "WG_STATUS=OK"
  RESULT=0
else
  echo "WG_STATUS=FAIL"
  RESULT=1
fi

sudo ip link del "$CLIENT_IF" 2>/dev/null || true
exit $RESULT
