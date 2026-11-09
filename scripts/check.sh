#!/usr/bin/env bash
# The checks of the portal in the emulated router (a stock OpenWrt rootfs on a
# 128 MB flash with 512 MB of RAM).
#
#   check.sh install     the package: the files, the service, the answer of the
#                        portal, a removal and a second installation
#   check.sh wireguard   the whole chain: the portal manages a real WireGuard
#                        server interface, a client connects with the
#                        configuration the portal hands out and pings through
#                        the tunnel, and the guest pings the client back
set -euo pipefail

MODE=${1:-wireguard}
case "$MODE" in
  install | wireguard) ;;
  *)
    echo "usage: $0 {install|wireguard}" >&2
    exit 2
    ;;
esac

QEMU=${QEMU:-qemu-system-aarch64}
VM=${VM:-/tmp/wgp-vm}
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

GUEST_ROOT=$VM/rootfs
FEED=$VM/feed
WGP_FEED=$VM/wgp-feed
KEY=$VM/id_ed25519
CONSOLE=$VM/console-$MODE.log
FLASH=$VM/flash.img
PIDFILE=$VM/qemu.pid
# The ports the feeds are served on: the guest fetches the index and the
# packages of them from the host.
FEED_PORT=${FEED_PORT:-18080}
WGP_FEED_PORT=${WGP_FEED_PORT:-18081}
# The public key of the feed of the portal: the index of the feed is signed
# with it, and the guest trusts it.
PUBKEY=${PUBKEY:-$ROOT/keys/wg-portal.pem}

# The script needs root for the tap device, the WireGuard interface and the
# flash image. Inside the image it already is.
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"

# The values of the machine the guest runs on are read by scripts/guest.sh
# as well, so they have to be in its environment.
export QEMU MEM_MB BOOT_TIMEOUT LINK_HOST LINK_GUEST

cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  [ -f "$VM/feed.pid" ] && kill "$(cat "$VM/feed.pid")" 2>/dev/null || true
  [ -f "$VM/wgp-feed.pid" ] && kill "$(cat "$VM/wgp-feed.pid")" 2>/dev/null || true
  $SUDO ip link del "$CLIENT_IF" 2>/dev/null || true
  $SUDO ip link del "$TAP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$VM"
cd "$VM"

# The scratch files of a run as root are not writable by the user of the host,
# and the run fails on them.
rm -f "$CONSOLE" "$PIDFILE" "$VM/feed.log" "$VM/wgp-feed.log" \
  "$VM/feed.pid" "$VM/wgp-feed.pid" "$VM/peer.conf" "$VM/vars.json"

# The values of the emulated router are passed to the play with them.
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
    "rootfs": "$GUEST_ROOT",
    "feed_url": "http://$LINK_HOST:$FEED_PORT/packages.adb",
    "wgp_feed_url": "http://$LINK_HOST:$WGP_FEED_PORT/packages.adb",
    "feed_pubkey": "$PUBKEY"
  }
}
EOF

# --- the guest -------------------------------------------------------------------

echo "=== fetching the OpenWrt guest"
"$HERE/guest.sh" fetch "$VM"

echo "=== writing the network of the guest"
"$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
  --tags net -e @"$VM/vars.json"

echo "=== preparing the guest for Ansible"
"$HERE/guest.sh" bootstrap "$GUEST_ROOT" "$KEY"

echo "=== collecting the packages"
"$HERE/guest.sh" packages "$DIST" "$VM/pkgs" "$FEED" "$WGP_FEED"

echo "=== building the flash of the router"
"$HERE/guest.sh" flash "$GUEST_ROOT" "$FLASH" "$FLASH_MB"

# --- the router ------------------------------------------------------------------

"$HERE/guest.sh" boot "$FLASH" "$VM/kernel.bin" "$TAP" "$CONSOLE" "$PIDFILE"

# The feeds: apk knows no file:// url, so the guest fetches the index and
# the packages of them over HTTP from the host. The feed of the kernel
# modules is the one of OpenWrt, the feed of the portal is the one of this
# project — its index is signed with the key of the project.
echo "=== serving the feed of the kernel modules"
python3 -m http.server "$FEED_PORT" --directory "$FEED" --bind "$LINK_HOST" \
  > "$VM/feed.log" 2>&1 &
echo $! > "$VM/feed.pid"

echo "=== serving the feed of the portal"
python3 -m http.server "$WGP_FEED_PORT" --directory "$WGP_FEED" --bind "$LINK_HOST" \
  > "$VM/wgp-feed.log" 2>&1 &
echo $! > "$VM/wgp-feed.pid"

# --- the setup of the guest, by Ansible -------------------------------------------

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

# --- the check of the package ---------------------------------------------------------

if [ "$MODE" = install ]; then
  echo "=== checking the installation"
  "$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
    --tags package -e @"$VM/vars.json"

  echo "=== guest console saved to $CONSOLE"
  exit 0
fi

# --- the interface and the peer, through the API ----------------------------------------

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

# --- the client on the host ---------------------------------------------------------------

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

# --- the guest side of the tunnel, by Ansible ------------------------------------------------

echo "=== verifying the tunnel from the guest"
if ! "$ANSIBLE" -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/site.yml" \
     --tags verify -e @"$VM/vars.json"; then
  GUEST_PING="TUNNEL_PING=FAIL"
else
  GUEST_PING="TUNNEL_PING=OK"
fi

# --- the tunnel, from the client --------------------------------------------------------------

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
