# wg-portal for OpenWrt

A ready-to-install `.ipk` package of [WG Portal](https://github.com/h44z/wg-portal)
for the router of the LAN: RouteRich AX3000 v1 (`mediatek/filogic`,
`aarch64_cortex-a53`), kernel 6.6.144, **128 MB of flash and 512 MB of RAM**.

The flash of the router is the scarce resource and the RAM is not, so the
release binary of the portal is packed with UPX: 39.4 MB → 9.9 MB in the
flash, at the price of ~48 MB of RAM instead of ~31 MB — the router has 512
of them. The package is checked in an emulated OpenWrt with the very same
resources (128 MB of flash, 512 MB of RAM) before every release: the package
is installed there with opkg and a real WireGuard tunnel is made through it.

Releases: <https://github.com/nhths/wg-portal-openwrt/releases>
The upstream project: <https://github.com/h44z/wg-portal>

## Install

```sh
opkg install https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.ipk
```

The name of the asset is the same in every release, so the command does not
change; opkg upgrades to a newer version with the same command.

The dependency of the package — the WireGuard kernel module — opkg pulls in
itself from the feeds of the firmware, so the router needs the internet.

The package carries no configuration, so the portal needs one before the
first start:

```sh
mkdir -p /etc/wg-portal
cat > /etc/wg-portal/config.yaml <<'EOF'
core:
  admin_password: the-password-of-the-portal
web:
  listening_address: 0.0.0.0:8888
database:
  dsn: /etc/wg-portal/wg.db
EOF
```

The database has to be on the flash: `/tmp` is a tmpfs.

The traffic of the peers is not tracked by the connection tracking of the
firewall, so the interface of the tunnel needs a zone of its own — by
**device**, not by network (the interface is created by the portal itself and
is not in `/etc/config/network`):

```text
config zone
        option name 'wg'
        list device 'wg0'
        option input 'ACCEPT'
```

And then the service:

```sh
/etc/init.d/wg-portal enable
/etc/init.d/wg-portal start
```

The web UI is on the port of the config.

## Build

Docker with network access is required. The measurements and the checks
additionally need `qemu-system-aarch64`; the WireGuard check needs root (it
creates a tap device) and `ethtool`.

```sh
make dist           # download, pack with UPX, build the .ipk
make check-install  # install the .ipk in an emulated OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
```

`ARCH` is the exact value of `opkg print-architecture` on the router
(`aarch64_cortex-a53`); opkg refuses the package otherwise.

The details — the layout of the project, the emulation, the checks, the
release workflow and the notes of the measurements — are in
[AGENTS.md](AGENTS.md).
