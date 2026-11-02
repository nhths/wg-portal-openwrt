#!/usr/bin/env bash
# The entry point of the check image: run the WireGuard check and report the
# verdict as the exit code.
set -euo pipefail
cd /opt/wg-portal
exec ./scripts/check-wireguard.sh "$@"
