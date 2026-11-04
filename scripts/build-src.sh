#!/usr/bin/env bash
# Build wg-portal from source in a container and compare the result with the
# release binary. Touches nothing on the host but Docker.
#
#   VER=v2.3.1 ./scripts/build-src.sh
set -euo pipefail

VER=${VER:-v2.3.1}
DOCKER=${DOCKER:-docker}
PLATFORM=${PLATFORM:-linux/amd64}
SRC=${SRC:-$(mktemp -d)/wg-portal}
OUT=${OUT:-$(pwd)/dist}
REPO=https://github.com/h44z/wg-portal.git
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$OUT"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$VER" "$REPO" "$SRC"
fi

echo "=== building the builder image"
$DOCKER build --platform "$PLATFORM" -f "$(dirname "$HERE")/Dockerfile.builder" -t wg-portal-builder:local "$SRC"

# build_variant <name> <go build flags> [source tree preparation snippet]
build_variant() {
  local name=$1 flags=$2 prep=${3:-true}
  echo "=== variant: $name"
  $DOCKER run --rm --platform "$PLATFORM" \
    -v "$OUT:/out" \
    -v wg-portal-gocache:/root/.cache/go-build \
    wg-portal-builder:local \
    sh -c "cd /build && $prep && go build -o /out/wg-portal-$name $flags cmd/wg-portal/main.go"
  ls -l "$OUT/wg-portal-$name"
}

# Exactly the upstream Makefile flags: -w -s + netgo. Reproduces the release
# binary byte for byte (41 353 378 B for v2.3.1).
build_variant upstream \
  '-ldflags "-w -s -extldflags \"-static\"" -tags netgo'

# The same with the bundled assets trimmed: legacy font formats
# (eot/svg/ttf/otf) and the swagger documents. Saves 11 % of the binary but
# is not a production-ready build.
build_variant trimmed \
  '-ldflags "-w -s -extldflags \"-static\"" -tags netgo' \
  'find internal/app/api/core/assets/doc -type f -exec truncate -s 0 {} + && find internal/app/api/core/assets/fonts -type f \( -name "*.eot" -o -name "*.svg" -o -name "*.ttf" -o -name "*.otf" \) -exec truncate -s 0 {} +'

echo "=== summary"
ls -l "$OUT"
