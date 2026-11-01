#!/bin/sh
# /init of the install-check guest: a stock OpenWrt rootfs.
#
# Installs the .ipk with opkg, checks what landed on disk, removes the
# package again and finally starts the installed binary.
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
ip link set lo up
mkdir -p /var/lock /var/run /etc/opkg

echo "=== guest up: $(uname -a)"
echo "--- openwrt release:"; cat /etc/openwrt_release
echo "--- opkg print-architecture:"; opkg print-architecture

# opkg takes its architecture list from the "arch <name> <priority>" lines
# of /etc/opkg.conf (there is no /etc/opkg/arch.conf), and a single such
# line replaces the default list [all, noarch, <build arch>] instead of
# extending it. Write the whole list, including the router architecture.
printf "arch all 1\narch noarch 1\narch aarch64_generic 10\narch aarch64_cortex-a53 10\n" >> /etc/opkg.conf

# kmod-wireguard is not part of the stock rootfs. Without it opkg drops the
# candidate and reports a misleading "incompatible with the architectures
# configured". Marking it as installed resolves the dependency and keeps
# opkg from trying to install it.
mkdir -p /usr/lib/opkg /usr/lib/opkg/info
cat >> /usr/lib/opkg/status <<'PKGEOF'

Package: kmod-wireguard
Version: 6.6.144-r1
Depends: kernel (= 6.6.144~0b532dfcba2e5fa16405c5387dd37cae-r1)
Status: install ok installed
Architecture: aarch64_generic
Installed-Time: 1784877710
PKGEOF
# opkg also expects the metadata files of every installed package.
: > /usr/lib/opkg/info/kmod-wireguard.list
cat > /usr/lib/opkg/info/kmod-wireguard.control <<'CTRL'
Package: kmod-wireguard
Version: 6.6.144-r1
Status: install ok installed
Architecture: aarch64_generic
Installed-Size: 0
CTRL

cd /tmp || exit 1
echo "=== install"
opkg install --force-depends /tmp/wg-portal.ipk 2>&1 | tail -5
echo "--- installed files:"; ls -l /usr/bin/wg-portal /etc/init.d/wg-portal 2>&1
echo "--- rc.d:"; ls -l /etc/rc.d/S*wg-portal /etc/rc.d/K*wg-portal 2>/dev/null
echo "--- list-installed:"; opkg list-installed 2>/dev/null | grep wg-portal
echo "--- status:"; opkg status wg-portal 2>&1 | head -8

echo "=== remove"
opkg remove wg-portal 2>&1 | tail -3
ls -l /usr/bin/wg-portal 2>&1 | head -2

echo "=== start the installed binary"
opkg install --force-depends /tmp/wg-portal.ipk 2>&1 | tail -3
export WG_PORTAL_CONFIG=/etc/wg-portal/config.yaml
export WG_PORTAL_WEB_LISTENING_ADDRESS=127.0.0.1:8888
export WG_PORTAL_DATABASE_DSN=/tmp/wg.db
/usr/bin/wg-portal >/tmp/wg.log 2>&1 &
WPID=$!
i=0
while [ $i -lt 60 ]; do
  wget -q -O /dev/null http://127.0.0.1:8888/ 2>/dev/null && break
  sleep 1
  i=$((i + 1))
done
echo "--- http:"; wget -q -O /dev/null http://127.0.0.1:8888/ && echo HTTP_OK || echo HTTP_FAIL
echo "--- memory:"; grep -E "VmRSS|VmHWM" /proc/$WPID/status 2>/dev/null
echo "--- log:"; tail -5 /tmp/wg.log
kill $WPID 2>/dev/null

echo "=== install check done"
sync
poweroff -f
