#!/bin/sh
# The init of the measurement guest.
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
