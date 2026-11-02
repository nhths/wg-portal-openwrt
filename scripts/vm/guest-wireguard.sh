#!/bin/sh
# /init of the WireGuard check guest: a stock OpenWrt rootfs on the flash of
# the emulated router, with the wg-portal package and the WireGuard kernel
# modules.
#
# The portal manages a real WireGuard server interface here; the host
# connects to it as a client and pings through the tunnel.
mount -t proc     none /proc
mount -t sysfs    none /sys
# The OpenWrt armv8 kernel has no devtmpfs, the device nodes are created by
# hand.
mount -t tmpfs    tmpfs /dev 2>/dev/null
mknod /dev/null    c 1 3 2>/dev/null
mknod /dev/zero    c 1 5 2>/dev/null
mknod /dev/full    c 1 7 2>/dev/null
mknod /dev/random  c 1 8 2>/dev/null
mknod /dev/urandom c 1 9 2>/dev/null
mknod /dev/tty     c 5 0 2>/dev/null
mknod /dev/console c 5 1 2>/dev/null
ip link set lo up
mkdir -p /var/lock /var/run /etc/opkg /var/db

echo "=== guest up: $(uname -a)"

# The host and the guest are connected by a tap device, so the address is
# static (there is no DHCP server on that link).
. /tmp/net.conf
ip link set eth0 up
ip addr add "$LINK_ADDR" dev eth0
ip addr show eth0 | grep -w inet
echo "--- client: $CLIENT_ADDR"

# opkg takes its architecture list from the "arch <name> <priority>" lines of
# opkg.conf, and a single such line replaces the default list instead of
# extending it, so write the whole list.
printf "arch all 1\narch noarch 1\narch aarch64_generic 10\narch aarch64_cortex-a53 10\n" >> /etc/opkg.conf
# Everything is installed from the local files, the feeds are not needed and
# only slow the guest down.
rm -f /etc/opkg/distfeeds.conf

echo "=== installing the packages"
cd /tmp || exit 1
opkg install --force-depends /tmp/wg-portal.ipk /tmp/kmod-*.ipk

MODVER=$(ls /lib/modules | head -1)
echo "=== checking the wireguard modules from /lib/modules/$MODVER"
# The postinstall scripts of the kmod packages load the modules already, so
# modprobe only has to load what is still missing.
for m in libcurve25519-generic poly1305-neon libchacha20poly1305 udp_tunnel ip6_udp_tunnel wireguard; do
  if modprobe "$m" 2>/tmp/modprobe.err; then
    echo "loaded $m"
  else
    echo "FAILED $m: $(cat /tmp/modprobe.err)"
  fi
done

echo "=== starting wg-portal"
WG_PORTAL_CORE_ADMIN_PASSWORD=wg-portal-check-password
WG_PORTAL_WEB_LISTENING_ADDRESS=0.0.0.0:8888
WG_PORTAL_DATABASE_DSN=/tmp/wg.db
export WG_PORTAL_CORE_ADMIN_PASSWORD WG_PORTAL_WEB_LISTENING_ADDRESS WG_PORTAL_DATABASE_DSN
/usr/bin/wg-portal >/tmp/wg-portal.log 2>&1 &
PORTAL_PID=$!

i=0
while [ $i -lt 90 ]; do
  if wget -q -O /dev/null http://127.0.0.1:8888/api/v0/auth/providers 2>/dev/null; then
    break
  fi
  kill -0 $PORTAL_PID 2>/dev/null || break
  sleep 2
  i=$((i + 1))
done
echo "--- portal log:"; tail -5 /tmp/wg-portal.log
echo "PORTAL_READY"

# The host creates the interface and the peer through the API and connects as
# a client. Wait until the tunnel carries traffic, then report the counters.
i=0
while [ $i -lt 300 ]; do
  if ip link show wg0 >/dev/null 2>&1; then
    ip addr show wg0 2>/dev/null | grep -w inet
    break
  fi
  sleep 2
  i=$((i + 1))
done
echo "--- wg0:"; ip link show wg0 2>&1

echo "=== waiting for the tunnel traffic"
i=0
while [ $i -lt 300 ]; do
  RX=$(cat /sys/class/net/wg0/statistics/rx_bytes 2>/dev/null || echo 0)
  TX=$(cat /sys/class/net/wg0/statistics/tx_bytes 2>/dev/null || echo 0)
  if [ "${RX:-0}" -gt 0 ] 2>/dev/null && [ "${TX:-0}" -gt 0 ] 2>/dev/null; then
    echo "TUNNEL_TRAFFIC rx=$RX tx=$TX"
    break
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "--- rx=$RX tx=$TX"
  fi
  sleep 2
  i=$((i + 1))
done

# The handshake is the first traffic in the tunnel, the host pings the server
# right after it. Wait for that, then check the other direction.
sleep 30
echo "=== pinging the client through the tunnel"
if ping -c 3 -W 3 "$CLIENT_ADDR"; then
  echo "TUNNEL_PING=OK"
else
  echo "TUNNEL_PING=FAIL"
fi
RX=$(cat /sys/class/net/wg0/statistics/rx_bytes 2>/dev/null || echo 0)
TX=$(cat /sys/class/net/wg0/statistics/tx_bytes 2>/dev/null || echo 0)
echo "TUNNEL_TRAFFIC rx=$RX tx=$TX"

echo "=== guest done"
sync
poweroff -f
