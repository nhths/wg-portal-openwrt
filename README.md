# wg-portal for OpenWrt

A ready-to-install `.ipk` package of [WG Portal](https://github.com/h44z/wg-portal)
for the router of the LAN:

- board: RouteRich AX3000 v1 (`mediatek/filogic`)
- architecture: `aarch64_cortex-a53`
- kernel: 6.6.144
- **flash: 128 MB**
- **RAM: 512 MB**

The flash of the router is the scarce resource and the RAM is not, so the
release binary of the portal is packed with UPX: 39.4 MB → 9.9 MB in the
flash, at the price of ~48 MB of RAM instead of ~31 MB — the router has 512
of them. The package is checked in an emulated OpenWrt with the very same
resources (128 MB of flash, 512 MB of RAM) before every release: the package
is installed there with opkg and a real WireGuard tunnel is made through it.

Releases: <https://github.com/nhths/wg-portal-openwrt/releases>
The upstream project: <https://github.com/h44z/wg-portal>

## Install

### Through the feed

Every release carries a feed of its own: the index of the packages
(`Packages`), the signature of the index (`Packages.sig`) and the public key
of it (`wg-portal.pub`). The index is signed with `usign` — the tool OpenWrt
signs its own feeds with — and opkg checks the signature against the keys
the router trusts.

On the router:

```sh
wget -O /tmp/wg-portal.pub https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.pub
usign -F -p /tmp/wg-portal.pub
opkg-key add /tmp/wg-portal.pub
echo 'src wgp https://github.com/nhths/wg-portal-openwrt/releases/latest/download' >> /etc/opkg/customfeeds.conf
opkg update
opkg install wg-portal
```

The url of the feed is a directory: opkg takes `Packages` and `Packages.sig`
from it by itself, and the package of the index from the same directory.

`usign -F -p` prints the fingerprint of the key — it has to be
`4aae624e9d888fea`. The public half of the key is in the repository
([keys/wg-portal.pub](keys/wg-portal.pub)), so the fingerprint can be
compared with it before the key is trusted.

The dependency of the package — the WireGuard kernel module — opkg pulls in
itself from the feeds of the firmware, so the router needs the internet.

### Through the url of the package

If the feed is not wanted, the package can be installed by its url:

```sh
opkg install https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.ipk
```

The name of the asset is the same in every release, so the command always
gives the current version — running it again updates the package. But opkg
does not know where the package came from, so it cannot update it by
itself: that is what the feed is for.

### With Ansible

The play `ansible/router.yml` does the same on the LAN router: it trusts the
key of the feed, points opkg at the feed and installs the portal from it.
The router is not in the inventory of this project — the inventory that owns
it is the one of the serverside repo (the group `[openwrt_hosts]`, the host
`router`), so it is passed with `-i`:

```sh
ansible-playbook -i ../../ansible/inventory.ini ansible/router.yml
```

The path is from the root of this project, which lives in `separated/` of the
serverside repo. Any inventory with that host works.

The play checks the fingerprint of the key before it trusts it: the key has
to be the one of the project (`4aae624e9d888fea`).

The configuration of the portal, the zone of the firewall and the service are
not in the play — they need the password of the portal, and they are below.

### Configuration

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

## Update

With the feed in place, opkg sees the new versions:

```sh
opkg update
opkg upgrade wg-portal
```

The router can do it on its own — once a night, for example:

```sh
echo '0 4 * * * opkg update && opkg upgrade wg-portal >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart
```

The play does the same: run it again and the portal is upgraded to the
version of the feed.

## Build

Docker with network access is required. The measurements and the checks
additionally need `qemu-system-aarch64`; the WireGuard check needs root (it
creates a tap device) and `ethtool`.

```sh
make dist           # download, pack with UPX, build the .ipk
make feed           # build the index of the feed and sign it
make check-install  # install the .ipk in an emulated OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
```

`ARCH` is the exact value of `opkg print-architecture` on the router
(`aarch64_cortex-a53`); opkg refuses the package otherwise.

`make feed` signs the index with the secret key of the project. The secret
key is not in the repository: it lives in `~/.config/wg-portal/secret.key`
for the local runs and in the secrets of the CI for the releases. The public
key is in the repository.

The details — the layout of the project, the emulation, the checks, the
release workflow and the notes of the measurements — are in
[AGENTS.md](AGENTS.md).
