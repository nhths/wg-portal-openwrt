#!/usr/bin/env bash
# Download the wg-portal release binary, pack it with UPX and build the .ipk
# package.
#
# Runs in the toolbox image (Dockerfile.pkg), which brings UPX, GNU tar and
# Jinja2:
#
#   docker build -f Dockerfile.pkg -t wg-portal-pkg:local .
#   docker run --rm -v "$PWD/dist:/w" wg-portal-pkg:local
#
# The files of the package are templates (templates/ipk/) — they are rendered
# with Jinja2, the syntax the play of the router uses as well.
#
# Compression mode: --best --lzma. Measured on v2.3.1 / linux-arm64:
#
#   original        41 353 378 B (100 %)
#   --best          14 119 956 B (34.1 %)
#   --lzma          10 440 828 B (25.3 %)
#   --best --lzma   10 371 636 B (25.1 %)   <- smallest, used here
#
# The two other modes are not kept: they only waste space, LZMA alone is
# already close to the best result and --best adds 70 KB on top of it.
set -euo pipefail

VER=${VER:-v2.3.1}
ARCH=${ARCH:-aarch64_cortex-a53}
REL=${REL:-1}
# The directory of the artifacts, the one the toolbox image is given.
W=${W:-/w}
# The templates of the package.
TEMPLATES=${TEMPLATES:-/opt/wg-portal/templates/ipk}
REPO=https://github.com/h44z/wg-portal/releases/download

cd "$W"

# --- the binary ------------------------------------------------------------------

if [ ! -f wg-portal.orig ]; then
  echo "=== downloading the release binary"
  curl -fL -o wg-portal.orig "$REPO/$VER/wg-portal_linux_arm64"
fi
chmod +x wg-portal.orig
file wg-portal.orig

# --- the packing ------------------------------------------------------------------

echo "=== packing with UPX (--best --lzma)"
cp wg-portal.orig wg-portal.packed
upx --best --lzma wg-portal.packed
upx -t wg-portal.packed
ls -l wg-portal.orig wg-portal.packed

# --- the package --------------------------------------------------------------------

# The layout is the one of the stock OpenWrt ipkg-build: an outer tar.gz
# holding debian-binary, control.tar.gz and data.tar.gz.
echo "=== building the .ipk"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/data/usr/bin" "$TMP/data/etc/init.d" "$TMP/control"
install -m 755 wg-portal.packed "$TMP/data/usr/bin/wg-portal"

# The template and the file to write. The variables of the template are the
# environment of the renderer.
render() {
  python3 - "$TEMPLATES/$1.j2" "$2" <<'EOF'
import os
import sys

from jinja2 import Environment, StrictUndefined

src, dest = sys.argv[1], sys.argv[2]
environment = Environment(undefined=StrictUndefined, keep_trailing_newline=True)
with open(src) as f:
    template = environment.from_string(f.read())
with open(dest, "w") as f:
    f.write(template.render(**os.environ))
EOF
}

export PKG_VER=${VER#v} ARCH REL
render init.d "$TMP/data/etc/init.d/wg-portal"
chmod 755 "$TMP/data/etc/init.d/wg-portal"
render postinst "$TMP/control/postinst"
render prerm "$TMP/control/prerm"
chmod 755 "$TMP/control/postinst" "$TMP/control/prerm"

# opkg reads Installed-Size in bytes (it divides by 1024 itself), the same
# as in the stock OpenWrt packages.
SIZE=$(du -sb "$TMP/data" | cut -f1)
export SIZE
render control "$TMP/control/control"

tar --numeric-owner --owner=0 --group=0 -C "$TMP/data"    -czf "$TMP/data.tar.gz" .
tar --numeric-owner --owner=0 --group=0 -C "$TMP/control" -czf "$TMP/control.tar.gz" .
echo 2.0 > "$TMP/debian-binary"
OUT=wg-portal_${PKG_VER}-${REL}_$ARCH.ipk
tar -C "$TMP" -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz
ls -l ./*.ipk
