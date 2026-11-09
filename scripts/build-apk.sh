#!/usr/bin/env bash
# Download the wg-portal release binary, pack it with UPX and build the .apk
# package. Runs in the toolbox image (Dockerfile.pkg).
#
# The version of the package is four numbers: the three of the version of the
# portal and the fourth one is ours (PKG_REV).
set -euo pipefail

VER=${VER:-v2.3.1}
# The revision of the packaging: the fourth number of the version of the
# package. It is bumped when the packaging changes.
PKG_REV=${PKG_REV:-1}
ARCH=${ARCH:-aarch64_cortex-a53}
# The version of the package: the version of the portal and our revision.
PKG_VERSION=${PKG_VERSION:-${VER#v}.$PKG_REV}
# The directory of the artifacts, the one the toolbox image is given.
W=${W:-/w}
# The templates of the package.
TEMPLATES=${TEMPLATES:-/opt/wg-portal/templates/apk}
# The secret key of the feed: the package is signed with it.
SECRET=${SECRET:-/key/secret.pem}
# The ids of the user of the host. The container runs as root, so that the
# files of the package belong to root — apk records the uid and the gid of
# the builder, and a package built by a user gets nobody:nobody.
HOST_UID=${HOST_UID:-}
HOST_GID=${HOST_GID:-}
REPO=https://github.com/h44z/wg-portal/releases/download

cd "$W"

# --- the binary ------------------------------------------------------------------

if [ ! -f wg-portal.orig ]; then
  echo "=== downloading the release binary"
  # The CDN of the releases of GitHub answers with a 504 now and then: the
  # download is repeated before the build gives up.
  curl -fL --retry 5 --retry-delay 5 --retry-all-errors \
    -o wg-portal.orig "$REPO/$VER/wg-portal_linux_arm64"
fi
chmod +x wg-portal.orig
file wg-portal.orig
# A download that was cut short leaves a file that is not the binary.
file wg-portal.orig | grep -q 'ARM aarch64' \
  || { echo "wg-portal.orig is not an aarch64 ELF" >&2; exit 1; }

# --- the packing ------------------------------------------------------------------

echo "=== packing with UPX (--best --lzma)"
cp wg-portal.orig wg-portal.packed
upx --best --lzma wg-portal.packed
upx -t wg-portal.packed
ls -l wg-portal.orig wg-portal.packed

# --- the package --------------------------------------------------------------------

# The tree of the package is the root of it: the files of the package are
# under it, exactly as they are on the router.
echo "=== building the .apk"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -f "$SECRET" ] || { echo "no secret key in $SECRET" >&2; exit 1; }

ROOT=$TMP/root
mkdir -p "$ROOT/usr/bin" "$ROOT/etc/init.d" "$ROOT/lib/apk/packages"
install -m 755 wg-portal.packed "$ROOT/usr/bin/wg-portal"

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

export PKG_VERSION ARCH
render init.d "$ROOT/etc/init.d/wg-portal"
chmod 755 "$ROOT/etc/init.d/wg-portal"
render post-install "$TMP/post-install"
render post-upgrade "$TMP/post-upgrade"
render pre-deinstall "$TMP/pre-deinstall"
chmod 755 "$TMP/post-install" "$TMP/post-upgrade" "$TMP/pre-deinstall"

# The list of the files of the package: OpenWrt reads it in the scripts of
# the packages. It is made before the list itself is put in place, so the
# list does not mention itself.
(cd "$ROOT" && find . -type f,l -printf "/%P\n" | sort) > "$TMP/list"
mv "$TMP/list" "$ROOT/lib/apk/packages/wg-portal.list"

render metadata "$TMP/metadata"
INFO=()
while IFS= read -r line; do
  [ -n "$line" ] && INFO+=(--info "$line")
done < "$TMP/metadata"

apk mkpkg \
  --sign-key "$SECRET" \
  "${INFO[@]}" \
  --script "post-install:$TMP/post-install" \
  --script "post-upgrade:$TMP/post-upgrade" \
  --script "pre-deinstall:$TMP/pre-deinstall" \
  --files "$ROOT" \
  --output "wg-portal-${PKG_VERSION}.apk"

# The artifacts of the build belong to the user of the host. The chown fails
# in a rootless podman — the ids of the host are not mapped in it — and it
# does not matter there: the files are his already.
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
  chown "$HOST_UID:$HOST_GID" ./*.apk wg-portal.orig wg-portal.packed 2>/dev/null || true
fi

ls -l ./*.apk
