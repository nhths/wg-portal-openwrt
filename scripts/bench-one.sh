#!/bin/sh
# Start one wg-portal binary and measure its startup time and RSS.
#
# POSIX sh, so it runs in the measurement guest (busybox), in an Alpine
# container and directly on the router.
#
# Usage: bench-one.sh /path/to/wg-portal
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
