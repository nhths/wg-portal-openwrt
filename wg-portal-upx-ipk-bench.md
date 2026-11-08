# Task for the agent: pack, measure and test wg-portal, build an opkg package

> This is the original task brief. The work it describes has been done — see
> [README.md](README.md) for the results and the current layout.

Goal: take the ready-made WG Portal binary for arm64, pack it with UPX in
several modes, compare the size, the startup time and the RAM usage, verify
that the packed binary really runs (in Docker), and build an `.ipk` for
OpenWrt. Configuring the portal is not needed: the environment variables from
`bench-one.sh` are enough for the test.

Version: WG Portal v2.3.1 (the latest release on 1 November 2026). The ready
binaries are in the release: `wg-portal_linux_arm64`, `wg-portal_linux_amd64`,
`wg-portal_linux_arm_v7`. Building from source is not needed: it requires
Go 1.25+ and a separate frontend build (`make frontend`, Node 18+).

Host requirements: Docker, network access. On an x86 host without Docker
Desktop, for running arm64 containers, run this once:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

## Structure

```text
work/
  run.sh
  bench-one.sh
  make-ipk.sh
```

The layout above is the one of the brief. In the repository today
`bench-one.sh` is a file of its own (`scripts/bench-one.sh`), copied by
`scripts/bench.sh` into the initramfs of the measurement guest, and so is the
init of that guest (`scripts/bench-init.sh`). The packaging is the script
`scripts/build-apk.sh` with the templates in `templates/apk/` — the router
runs OpenWrt 25.12 now, and its package manager is apk, not opkg.

## run.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
VER=${VER:-v2.3.1}
ARCH=${ARCH:-aarch64_cortex-a53}   # exact value: opkg print-architecture on the router
cd "$(dirname "$0")"

# 1. download the original
[ -f wg-portal.orig ] || curl -fL -o wg-portal.orig \
  https://github.com/h44z/wg-portal/releases/download/$VER/wg-portal_linux_arm64
chmod +x wg-portal.orig

# 2. pack (UPX packs a foreign architecture without running it)
docker run --rm -v "$PWD":/w -w /w alpine:3.20 sh -c '
  apk add --no-cache upx file binutils >/dev/null
  echo "--- original: stripped?"
  file wg-portal.orig
  echo "debug sections: $(readelf -S wg-portal.orig | grep -c debug || true)"
  cp wg-portal.orig wg-portal.best;     upx --best          wg-portal.best
  cp wg-portal.orig wg-portal.lzma;     upx --lzma          wg-portal.lzma
  cp wg-portal.orig wg-portal.bestlzma; upx --best --lzma   wg-portal.bestlzma
  for f in wg-portal.best wg-portal.lzma wg-portal.bestlzma; do upx -t $f; done
'
echo "--- sizes"
ls -l wg-portal.orig wg-portal.best wg-portal.lzma wg-portal.bestlzma

# 3. run and measure every variant in an arm64 container
for v in orig best lzma bestlzma; do
  echo "=== $v"
  docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.20 \
    sh /w/bench-one.sh /w/wg-portal.$v
done

# 4. build the ipk (replace bestlzma with the chosen variant)
docker run --rm -v "$PWD":/w -w /w debian:stable-slim \
  bash /w/make-ipk.sh "$ARCH" /w/wg-portal.bestlzma "$VER"
ls -l ./*.ipk
```

## bench-one.sh

POSIX sh, works both in an Alpine container and directly on the router
(busybox): `sh bench-one.sh /tmp/wg-portal.bestlzma`.

```sh
#!/bin/sh
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
for i in $(seq 1 150); do
  if wget -q -O /dev/null http://127.0.0.1:8888/ 2>/dev/null; then ok=1; break; fi
  kill -0 $PID 2>/dev/null || break
  sleep 0.2
done
t1=$(now)

if [ $ok -eq 1 ]; then echo "STATUS=OK startup_s=$(awk "BEGIN{print $t1-$t0}")"; else echo "STATUS=FAIL"; tail -n 20 /tmp/bench.log; fi
sleep 5
grep -E 'VmRSS|VmHWM' /proc/$PID/status 2>/dev/null
kill $PID 2>/dev/null
rm -f /tmp/bench.db
```

How to read the results:

- `STATUS=OK` means the binary unpacked, started and the UI answers over
  HTTP. That is the check that UPX did not break the binary.
- On `FAIL`, look at the tail of the log. A complaint about the kernel or
  netlink inside the container is possible (there is no WireGuard module
  there); in that case add `--privileged` to the container and compare with
  `orig`: if `orig` fails the same way, it is a limitation of the environment,
  not of UPX.
- In a container on an x86 host the process goes through qemu, so the
  absolute `VmRSS` and `VmHWM` are unreliable. The comparison between the
  variants is still meaningful. Only a native arm64 host or the router itself
  gives real numbers: copy the binaries and `bench-one.sh` to `/tmp` on the
  router and run them there.
- The expected effect of UPX: the size on disk drops, while the RSS grows,
  because the unpacked image sits in anonymous memory as a whole. If the RSS
  difference is too large for your amount of RAM, take the unpacked variant.

## make-ipk.sh

Run in a GNU environment (the `debian:stable-slim` container from `run.sh`).
The format is the same as the stock OpenWrt `ipkg-build`: an outer tar.gz of
`debian-binary`, `control.tar.gz`, `data.tar.gz`.

```bash
#!/usr/bin/env bash
# Usage: make-ipk.sh <opkg-architecture> <path-to-binary> <version, e.g. v2.3.1>
set -euo pipefail
ARCH=${1:?architecture from opkg print-architecture}
BIN=${2:?path to the binary}
VER=${3:?version}
VER=${VER#v}
REL=1
W=$(mktemp -d)

mkdir -p $W/data/usr/bin $W/data/etc/init.d $W/control
install -m 755 $BIN $W/data/usr/bin/wg-portal

cat > $W/data/etc/init.d/wg-portal <<'EOF'
#!/bin/sh /etc/rc.common
START=99
STOP=01
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/wg-portal
    procd_set_param env WG_PORTAL_CONFIG=/etc/wg-portal/config.yaml
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod 755 $W/data/etc/init.d/wg-portal

cat > $W/control/postinst <<'EOF'
#!/bin/sh
[ -z "$IPKG_INSTROOT" ] && /etc/init.d/wg-portal enable
exit 0
EOF
cat > $W/control/prerm <<'EOF'
#!/bin/sh
if [ -z "$IPKG_INSTROOT" ]; then
    /etc/init.d/wg-portal stop
    /etc/init.d/wg-portal disable
fi
exit 0
EOF
chmod 755 $W/control/postinst $W/control/prerm

SIZE=$(du -sb $W/data | cut -f1)
cat > $W/control/control <<EOF
Package: wg-portal
Version: $VER-$REL
Depends: kmod-wireguard
Section: net
Architecture: $ARCH
Installed-Size: $SIZE
Maintainer: you <you@example.com>
Description: WireGuard Portal - web UI for WireGuard
EOF

tar --numeric-owner --owner=0 --group=0 -C $W/data    -czf $W/data.tar.gz .
tar --numeric-owner --owner=0 --group=0 -C $W/control -czf $W/control.tar.gz .
echo 2.0 > $W/debian-binary
OUT=wg-portal_$VER-${REL}_$ARCH.ipk
tar -C $W -czf $OUT ./debian-binary ./control.tar.gz ./data.tar.gz
echo built: $OUT
```

The package carries no config: the path `/etc/wg-portal/config.yaml` in the
init script is there for future use. If the file should not be required, drop
the `procd_set_param env` line.

## Checking the package

Structure:

```sh
tar -tzf wg-portal_*.ipk
tar -xzOf wg-portal_*.ipk ./control.tar.gz | tar -xzO ./control
tar -xzOf wg-portal_*.ipk ./data.tar.gz | tar -tzv
```

There must be three files in the outer archive, a `control` file with the
right `Architecture`, and in the data `usr/bin/wg-portal` (755) and
`etc/init.d/wg-portal` (755).

Installation in an OpenWrt container (optional). The `openwrt/rootfs` images
are published under tags like `<arch>-<version>`; check the exact tag on
Docker Hub, you need the 24.10 branch or older, where opkg still exists:

```sh
docker run --rm --platform linux/arm64 -v "$PWD":/w openwrt/rootfs:<arch>-<version> sh -c '
  mkdir -p /var/lock /var/run
  opkg install --force-depends /w/wg-portal_*.ipk && ls -l /usr/bin/wg-portal /etc/init.d/wg-portal
'
```

`--force-depends` is needed because `kmod-wireguard` cannot be installed in
the container. The real check is on the router: `opkg install
/tmp/wg-portal_*.ipk` and `/etc/init.d/wg-portal start`. The `ARCH` value must
match the line from `opkg print-architecture` exactly, otherwise opkg refuses
to install the package.

## Important: the OpenWrt version

Starting with OpenWrt 25.12 (March 2026) the package manager is apk, not
opkg, and `.ipk` files are not installed there. The 24.10 branch (opkg) has
had no security updates since September 2026. If the router runs 25.12 or
newer, use `apk mkpkg` (apk-tools 3) instead of `make-ipk.sh` and install with
`apk add --allow-untrusted`; check the metadata field syntax against
`apk-package(5)`, it has not been run here.

## What was not checked

The scripts are written but were not run: my environment has no network
access. The real sizes of the release binary, the effect of each UPX mode and
the RAM consumption are unknown in advance and are determined only by this
run.
