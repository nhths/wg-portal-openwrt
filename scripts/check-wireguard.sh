#!/usr/bin/env bash
# End-to-end WireGuard check.
#
# The packaged wg-portal runs in an emulated OpenWrt guest and manages a real
# WireGuard server interface. Ansible sets the guest up (the OpenWrt setup:
# the packages, the kernel modules, the configuration and the service), a client
# on the host uses the configuration the portal hands out and pings through the
# tunnel.
#
# The two are connected by a tap device, not by the user-mode network of QEMU:
# slirp rewrites the UDP endpoints of the forwarded ports, and a WireGuard peer
# only accepts the handshake response from the address it sent the request to.
# Over a tap the endpoint of the client stays the same in both directions.
set -euo pipefail

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

GUEST_ROOT=$VM/rootfs
PACKAGES=$VM/packages
KEY=$VM/id_ed25519
CONSOLE=$VM/console-wg.log
FLASH=$VM/flash.img

# The script needs root for the tap device, the WireGuard interface and the
# flash image. Inside the image it already is.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

cleanup() {
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  $SUDO ip link del "$CLIENT_IF" 2>/dev/null || true
  $SUDO ip link del "$TAP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$VM" "$PACKAGES"
cd "$VM"

# --- the guest ----------------------------------------------------------------

echo "=== fetching the OpenWrt guest"
"$HERE/vm/fetch-guest.sh" "$VM"

# --- the bootstrap of the guest ------------------------------------------------

# The setup of the guest is done by Ansible over SSH, so the guest has to be
# reachable before Ansible can start. Two things are baked into the flash for
# that: the address of the guest (the link has no DHCP server) and the key
# Ansible logs in with.
echo "=== preparing the guest for Ansible"
"$HERE/vm/bootstrap-guest.sh" "$GUEST_ROOT" "$KEY" "$LINK_GUEST"

# --- the packages ---------------------------------------------------------------

echo "=== collecting the packages"
"$HERE/vm/collect-packages.sh" "$DIST" "$PACKAGES" "$VM/pkgs"

# --- the flash -----------------------------------------------------------------

echo "=== building the flash of the router"
"$HERE/vm/build-flash.sh" "$GUEST_ROOT" "$FLASH" "$FLASH_MB"

# --- the link between the host and the guest ------------------------------------

echo "=== connecting the host and the guest with $TAP"
$SUDO ip link del "$TAP" 2>/dev/null || true
$SUDO ip tuntap add dev "$TAP" mode tap
$SUDO ip addr add "$LINK_HOST/24" dev "$TAP"
$SUDO ip link set "$TAP" up
# The offloads of the tap are not understood by the guest: with the checksum
# and segmentation offload on, the packets arrive broken.
$SUDO ethtool -K "$TAP" tso off gso off gro off tx off sg off 2>/dev/null || true

# --- the router ----------------------------------------------------------------

echo "=== booting $QEMU"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m "$MEM_MB" -nographic -no-reboot \
  -kernel "$VM/kernel.bin" \
  -drive "file=$FLASH,format=raw,if=virtio" \
  -append "root=/dev/vda rootfstype=ext4 rw rootwait console=ttyAMA0" \
  -netdev "tap,id=net0,ifname=$TAP,script=no,downscript=no" \
  -device virtio-net-pci,netdev=net0 \
  < /dev/null > "$CONSOLE" 2>&1 &
QEMU_PID=$!

# --- the OpenWrt setup, by Ansible ----------------------------------------------

cat > "$VM/vars.json" <<EOF
{
  "wgp_overrides": {
    "link_guest": "$LINK_GUEST",
    "client_addr": "$CLIENT_ADDR",
    "server_addr": "$SERVER_ADDR",
    "web_port": $WEB_PORT,
    "wg_port": $WG_PORT,
    "admin_password": "$ADMIN_PASSWORD",
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

# Dropbear generates its host keys on the first boot, and under the emulation
# that takes minutes. The keys are kept in the rootfs, so the next run does
# not have to generate them again. The legacy protocol is forced: dropbear has
# no SFTP server.
scp -O -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "root@$LINK_GUEST:/etc/dropbear/*_key" "$GUEST_ROOT/etc/dropbear/" 2>/dev/null || true

# --- the interface and the peer, through the API --------------------------------

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

# --- the client on the host -----------------------------------------------------

# The addresses of the tunnel have to be free on the host. An address that is
# local here makes the answers of the router arrive with a source address
# that is local as well, and the host drops them as a martian source — the
# tunnel would carry the traffic and nothing would answer.
for addr in "$SERVER_ADDR" "$CLIENT_ADDR"; do
  if ip -4 -o addr show | grep -q " $addr/"; then
    echo "the address $addr is already in use on this host" >&2
    echo "the check needs the network $SUBNET to be free, or its own network namespace" >&2
    exit 1
  fi
done

echo "=== bringing up the client"
KEYFILE=$(mktemp)
PSKFILE=$(mktemp)
chmod 600 "$KEYFILE" "$PSKFILE"
printf '%s\n' "$PRIVKEY" > "$KEYFILE"
printf '%s\n' "$PSK" > "$PSKFILE"

$SUDO ip link del "$CLIENT_IF" 2>/dev/null || true
$SUDO ip link add "$CLIENT_IF" type wireguard
$SUDO ip addr add "$CLIENT_ADDR/32" dev "$CLIENT_IF"
$SUDO wg set "$CLIENT_IF" private-key "$KEYFILE" \
  peer "$SERVERKEY" preshared-key "$PSKFILE" \
  allowed-ips "$CLIENT_IPS" endpoint "$LINK_GUEST:$WG_PORT" \
  persistent-keepalive 25
$SUDO ip link set "$CLIENT_IF" up
# The kernel does not route the allowed IPs of a peer on its own, the route to
# the server network has to go into the tunnel explicitly.
$SUDO ip route add "$CLIENT_IPS" dev "$CLIENT_IF"
rm -f "$KEYFILE" "$PSKFILE"

# --- the guest side of the tunnel, by Ansible ------------------------------------

echo "=== verifying the tunnel from the guest"
if ! "$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
     --tags verify -e @"$VM/vars.json"; then
  GUEST_PING="TUNNEL_PING=FAIL"
else
  GUEST_PING="TUNNEL_PING=OK"
fi

# --- the tunnel, from the client ------------------------------------------------

# The ping comes after the verification of the guest: the firewall of the
# router has to know the tunnel interface before the client can reach the
# address of the tunnel.
echo "=== pinging through the tunnel"
sleep 2
if ping -c 3 -W 3 -I "$CLIENT_IF" "$SERVER_ADDR"; then
  PING_OK=1
else
  PING_OK=0
fi

echo "=== client state"
$SUDO wg show "$CLIENT_IF"

echo "=== guest console"
tail -25 "$CONSOLE"

if [ "$PING_OK" = 1 ] && [ "$GUEST_PING" = "TUNNEL_PING=OK" ]; then
  echo "WG_STATUS=OK"
  RESULT=0
else
  echo "WG_STATUS=FAIL"
  RESULT=1
fi

$SUDO ip link del "$CLIENT_IF" 2>/dev/null || true
exit $RESULT
