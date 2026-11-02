#!/usr/bin/env bash
# Download the wg-portal release binary, pack it with UPX and build the .ipk.
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
DOCKER=${DOCKER:-docker}
PLATFORM=${PLATFORM:-linux/amd64}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
DIST=${DIST:-$ROOT/dist}

mkdir -p "$DIST"
cd "$DIST"

if [ ! -f wg-portal.orig ]; then
  curl -fL -o wg-portal.orig \
    "https://github.com/h44z/wg-portal/releases/download/$VER/wg-portal_linux_arm64"
fi
chmod +x wg-portal.orig

echo "=== packing with UPX (--best --lzma)"
"$DOCKER" run --rm --platform "$PLATFORM" -v "$DIST":/w -w /w \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" alpine:3.20 sh -c '
  apk add --no-cache upx file binutils >/dev/null
  file wg-portal.orig
  cp wg-portal.orig wg-portal.packed
  upx --best --lzma wg-portal.packed
  upx -t wg-portal.packed
  chown "$HOST_UID:$HOST_GID" wg-portal.packed
'
ls -l wg-portal.orig wg-portal.packed

echo "=== building the .ipk"
# The builder runs as the host user: the package must belong to the user who
# is going to install it, and a root-owned file cannot be chowned back.
"$DOCKER" run --rm --platform "$PLATFORM" --user "$(id -u):$(id -g)" \
  -v "$ROOT":/repo -w /repo/dist debian:stable-slim \
  bash /repo/scripts/make-ipk.sh "$ARCH" /repo/dist/wg-portal.packed "$VER"
ls -l ./*.ipk
