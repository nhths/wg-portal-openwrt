#!/usr/bin/env bash
# Assemble the .ipk package. Runs in a Debian container (needs tar with
# --numeric-owner); the package is written to the current directory.
#
# Usage: make-ipk.sh <opkg-architecture> <path-to-binary> <version>
#
# The layout is the one of the stock OpenWrt ipkg-build: an outer tar.gz
# holding debian-binary, control.tar.gz and data.tar.gz.
set -euo pipefail

ARCH=${1:?opkg architecture, e.g. aarch64_cortex-a53}
BIN=${2:?path to the wg-portal binary}
VER=${3:?version, e.g. v2.3.1}
VER=${VER#v}
REL=${REL:-1}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

mkdir -p "$W/data/usr/bin" "$W/data/etc/init.d" "$W/control"
install -m 755 "$BIN" "$W/data/usr/bin/wg-portal"

cat > "$W/data/etc/init.d/wg-portal" <<'EOF'
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
chmod 755 "$W/data/etc/init.d/wg-portal"

cat > "$W/control/postinst" <<'EOF'
#!/bin/sh
[ -z "$IPKG_INSTROOT" ] && /etc/init.d/wg-portal enable
exit 0
EOF
cat > "$W/control/prerm" <<'EOF'
#!/bin/sh
if [ -z "$IPKG_INSTROOT" ]; then
    /etc/init.d/wg-portal stop
    /etc/init.d/wg-portal disable
fi
exit 0
EOF
chmod 755 "$W/control/postinst" "$W/control/prerm"

# opkg reads Installed-Size in bytes (it divides by 1024 itself), the same
# as the stock OpenWrt packages do.
SIZE=$(du -sb "$W/data" | cut -f1)
cat > "$W/control/control" <<EOF
Package: wg-portal
Version: $VER-$REL
Depends: kmod-wireguard
Section: net
Architecture: $ARCH
Installed-Size: $SIZE
Maintainer: Nikita Koschin <nik.koshin@mail.ru>
Description: WireGuard Portal - web UI for WireGuard
EOF

tar --numeric-owner --owner=0 --group=0 -C "$W/data"    -czf "$W/data.tar.gz" .
tar --numeric-owner --owner=0 --group=0 -C "$W/control" -czf "$W/control.tar.gz" .
echo 2.0 > "$W/debian-binary"
OUT=wg-portal_$VER-${REL}_$ARCH.ipk
tar -C "$W" -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz
echo "built: $OUT"
