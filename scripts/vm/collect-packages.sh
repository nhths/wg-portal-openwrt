#!/usr/bin/env bash
# Collect the packages the guest is set up with: the .ipk of the portal and the
# kernel modules of the WireGuard one, under the names the setup uses.
#
# Usage: collect-packages.sh <dist-dir> <target-dir> <kernel-modules-dir>
set -euo pipefail

DIST=${1:?the directory with the .ipk of the portal}
TARGET=${2:?the directory to collect the packages in}
KMODS=${3:?the directory with the kernel module packages}

mkdir -p "$TARGET"

IPK=$(ls "$DIST"/wg-portal_*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || { echo "no .ipk in $DIST — run 'make dist' first" >&2; exit 1; }
cp "$IPK" "$TARGET/wg-portal.ipk"

for pkg in kmod-wireguard kmod-crypto-lib-curve25519 kmod-crypto-lib-chacha20poly1305 \
           kmod-crypto-lib-poly1305 kmod-crypto-lib-chacha20 kmod-crypto-kpp \
           kmod-udptunnel4 kmod-udptunnel6; do
  file=$(ls "$KMODS/$pkg"_*.ipk 2>/dev/null | head -1)
  [ -n "$file" ] || { echo "the package $pkg is missing in $KMODS" >&2; exit 1; }
  cp "$file" "$TARGET/$pkg.ipk"
done

ls -l "$TARGET"
