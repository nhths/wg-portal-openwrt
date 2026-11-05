#!/usr/bin/env bash
# The feed of the portal: the index of the packages and the public key of it.
#
#   make-feed.sh <dist-dir> <public-key>
#
# The index is the list of the packages of the feed in the format of opkg:
# the fields of the control file of the package and the name, the size and
# the checksum of the file itself. The fields come from the control file of
# the .ipk, so the index cannot drift from the package.
#
# The signature of the index is not made here: it is made by usign, the tool
# of OpenWrt — the feeds of the firmware are signed the same way. The caller
# signs the index and puts the signature next to it.
set -euo pipefail

DIST=${1:?the directory with the package}
PUBKEY=${2:?the public key of the feed}

IPK=$(ls "$DIST"/wg-portal_*.ipk 2>/dev/null | head -1)
[ -n "$IPK" ] || { echo "no .ipk in $DIST — run 'make dist' first" >&2; exit 1; }
[ -f "$PUBKEY" ] || { echo "no public key in $PUBKEY" >&2; exit 1; }

NAME=$(basename "$IPK")
SIZE=$(stat -c %s "$IPK")
SHA=$(sha256sum "$IPK" | cut -d' ' -f1)

CONTROL=$(tar -xzOf "$IPK" ./control.tar.gz | tar -xzO ./control)

{
  printf '%s\n' "$CONTROL"
  printf 'Filename: %s\n' "$NAME"
  printf 'Size: %s\n' "$SIZE"
  printf 'SHA256sum: %s\n' "$SHA"
} > "$DIST/Packages"

cp "$PUBKEY" "$DIST/wg-portal.pub"

echo "=== the index of the feed"
cat "$DIST/Packages"
