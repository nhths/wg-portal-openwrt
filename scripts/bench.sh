#!/usr/bin/env bash
# Measure size, startup time and RAM usage of the packed binary inside a
# fully emulated arm64 guest.
#
# Why a guest and not a container: under qemu-user the call
# socket(AF_NETLINK, ..., NETLINK_GENERIC) returns EPROTONOSUPPORT, so
# wgctrl cannot be created and wg-portal panics on startup. A full system
# emulation has a real arm64 kernel and behaves like the device.
#
# The guest is an initramfs of Alpine with two scripts in it, written here:
# the init of the guest and the measurement of one binary.
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

[ -f vmlinuz-virt ] || curl -fsSL -O \
  "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64/netboot/vmlinuz-virt"
[ -f "alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz" ] || curl -fsSL -O \
  "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_SERIES}/releases/aarch64/alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"

echo "=== building the guest initramfs"
rm -rf root initramfs.gz
mkdir -p root
tar -xzf "alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz" -C root
mkdir -p root/proc root/sys root/dev root/tmp root/work
cp "$DIST/wg-portal.orig" "$DIST/wg-portal.packed" root/work/

# The init of the guest: it mounts what it needs and measures every binary in
# /work.
cat > root/init <<'INIT'
#!/bin/sh
mount -t proc     none /proc
mount -t sysfs    none /sys
mount -t devtmpfs none /dev
mount -t tmpfs    none /tmp
ip link set lo up

echo "=== guest up: $(uname -a)"
cd /work || exit 1
for v in orig packed; do
  echo "=== $v"
  sh /work/bench-one.sh /work/wg-portal.$v
done
echo "=== bench done"
sync
poweroff -f
INIT

# The measurement of one binary: the time until it answers and its RSS.
cat > root/work/bench-one.sh <<'BENCH'
#!/bin/sh
# Start one wg-portal binary and measure its startup time and RSS.
BIN=$1
export WG_PORTAL_CORE_ADMIN_PASSWORD=bench-password-1234567
export WG_PORTAL_WEB_LISTENING_ADDRESS=127.0.0.1:8888
export WG_PORTAL_WEB_EXTERNAL_URL=http://127.0.0.1:8888
export WG_PORTAL_DATABASE_DSN=/tmp/bench.db
export WG_PORTAL_STATISTICS_LISTENING_ADDRESS=127.0.0.1:8787

now() { awk '{print $1}' /proc/uptime; }
t0=$(now)
$BIN >/tmp/bench.log 2>&1 &
PID=$!

ok=0
i=0
while [ $i -lt 150 ]; do
  if wget -q -O /dev/null http://127.0.0.1:8888/ 2>/dev/null; then ok=1; break; fi
  kill -0 $PID 2>/dev/null || break
  sleep 0.2
  i=$((i + 1))
done
t1=$(now)

if [ $ok -eq 1 ]; then
  echo "STATUS=OK startup_s=$(awk "BEGIN{print $t1-$t0}")"
else
  echo "STATUS=FAIL"
  tail -n 20 /tmp/bench.log
fi
sleep 5
grep -E 'VmRSS|VmHWM' /proc/$PID/status 2>/dev/null
kill $PID 2>/dev/null
rm -f /tmp/bench.db
BENCH

chmod +x root/init root/work/bench-one.sh

( cd root && find . | cpio -o -H newc --quiet ) | gzip -1 > initramfs.gz
ls -l initramfs.gz

echo "=== booting $QEMU"
timeout "$BOOT_TIMEOUT" "$QEMU" \
  -M virt -cpu cortex-a53 -m 2048 -nographic -no-reboot \
  -kernel vmlinuz-virt \
  -initrd initramfs.gz \
  -append "console=ttyAMA0 rdinit=/init init=/init quiet" \
  < /dev/null 2>&1 | tee console.log

echo "=== guest console saved to $VM/console.log"
