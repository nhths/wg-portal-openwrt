#!/usr/bin/env bash
# The feed of the portal: the index of the packages and the signature of it.
#
# Runs in the toolbox image (Dockerfile.pkg), which brings the apk-tools: the
# index of the feed is the database of apk v3, and only apk itself writes it.
#
# The index is signed with the key of the project — an EC key of the curve
# P-256, the same kind the firmware of OpenWrt signs its own feeds with. The
# public half of it lives in /etc/apk/keys of the router, and apk checks the
# signature of the index against the keys it trusts there.
#
# The index is built from the package that is already signed: apk refuses to
# index a package whose signature it cannot check, and the keys of the feed
# are the ones it checks it against (--keys-dir).
set -euo pipefail

W=${W:-/w}
# The keys of the feed: the public one is in the repository, the secret one
# is in the secrets of the CI and, for the local runs, in the file below.
PUBKEY=${PUBKEY:-/keys/wg-portal.pem}
SECRET=${SECRET:-/key/secret.pem}

APK=$(ls "$W"/wg-portal-*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || { echo "no .apk in $W — run 'make dist' first" >&2; exit 1; }
[ -f "$PUBKEY" ] || { echo "no public key in $PUBKEY" >&2; exit 1; }
[ -f "$SECRET" ] || { echo "no secret key in $SECRET" >&2; exit 1; }

echo "=== the index of the feed"
apk --keys-dir "$(dirname "$PUBKEY")" mkndx \
  --sign-key "$SECRET" \
  --output "$W/packages.adb" \
  --description "The feed of the portal for the router of the LAN" \
  "$APK"
cp "$PUBKEY" "$W/wg-portal.pem"

# The artifacts belong to the user of the host — the container runs as root.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
  chown "$HOST_UID:$HOST_GID" "$W/packages.adb" "$W/wg-portal.pem" 2>/dev/null || true
fi

ls -l "$W/packages.adb" "$W/wg-portal.pem"
