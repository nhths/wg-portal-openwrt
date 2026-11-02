#!/usr/bin/env bash
# Prepare the guest for Ansible: the network of the guest and the key
# Ansible logs in with.
#
# Both are baked into the flash, because Ansible needs them to get into the
# guest at all: the link between the host and the guest has no DHCP server,
# and the key is the only way in. The stock rootfs carries no network
# configuration at all, so the loopback is written here as well — without it
# nothing on the guest can talk to itself, the portal included.
#
# Usage: bootstrap-guest.sh <rootfs-dir> <key-file> <address>
set -euo pipefail

ROOTFS=${1:?the rootfs directory}
KEY=${2:?the key file}
ADDRESS=${3:?the address of the guest}

if [ ! -f "$KEY" ]; then
  echo "=== generating the key Ansible logs in with"
  ssh-keygen -t ed25519 -N '' -f "$KEY" -q
fi

cat > "$ROOTFS/etc/config/network" <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1/8'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '$ADDRESS'
	option netmask '255.255.255.0'
EOF

mkdir -p "$ROOTFS/etc/dropbear"
cp "$KEY.pub" "$ROOTFS/etc/dropbear/authorized_keys"
chmod 600 "$ROOTFS/etc/dropbear/authorized_keys"
