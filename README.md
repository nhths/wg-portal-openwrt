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
(`Packages` and `Packages.gz`), the signature of the index (`Packages.sig`)
and the public key of it (`wg-portal.pub`). The index is signed with `usign`
— the tool OpenWrt signs its own feeds with — and opkg checks the signature
against the keys the router trusts.

On the router:

```sh
wget -O /tmp/wg-portal.pub https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.pub
usign -F -p /tmp/wg-portal.pub
opkg-key add /tmp/wg-portal.pub
tr -d '\000' < /etc/opkg/customfeeds.conf > /tmp/customfeeds.conf
echo 'src/gz wgp https://github.com/nhths/wg-portal-openwrt/releases/latest/download' >> /tmp/customfeeds.conf
cat /tmp/customfeeds.conf > /etc/opkg/customfeeds.conf
rm -f /tmp/customfeeds.conf
opkg update
opkg install wg-portal
```

The nulls are dropped on purpose: the firmware of this router ships
`/etc/opkg/customfeeds.conf` full of them, and opkg does not read such a
file — the feed of the portal stays invisible to it, and opkg answers
"Cannot install package wg-portal".

The url of the feed is a directory: opkg takes `Packages.gz` and
`Packages.sig` from it by itself, and the package of the index from the
same directory.

The index is published twice, as it is and compressed. The source of the
feed is declared as `src/gz` — the way the feeds of the firmware are declared
— so opkg takes the compressed one, and LuCI needs it as well: it reads the
indexes of the feeds with `gzip -cd`, which skips the files that are not
compressed. With a plain index only, the package is invisible to LuCI, and
the list of the installed packages shows it without a size and without a
description.

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

The play `ansible/router.yml` does the same on the LAN router: it fetches
the public key of the feed, checks its fingerprint, trusts it, points opkg
at the feed and installs the portal from it.

It is a single file with no dependencies of its own — it needs nothing but
Ansible and the access to the router. It can be piped straight from the
mirror into Ansible, without the repository and without a file on the disk:

```sh
curl -sSL https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/router.yml \
  | ansible-playbook /dev/stdin
```

The path of the playbook is `/dev/stdin`: `ansible-playbook -` does not read
the playbook from the pipe. If the file is wanted on the disk instead:

```sh
curl -sSLo router.yml https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/router.yml
ansible-playbook router.yml
```

The play fetches the public key of the feed itself, the address of the
router is a variable of it, and the inventory is not needed: the router is
registered by the play. (If the inventory has a host named `router`, that
one is used as it is — with the address of the inventory, and the variable
does not change it.)

The access is ssh as `root`, with the key of the machine the play runs on.
The address of the router is the default of the play — `192.168.0.1`.
Another address, another key:

```sh
ansible-playbook router.yml -e router_address=192.168.0.2 -e router_ssh_key=~/.ssh/id_ed25519
```

The play checks the fingerprint of the key before it trusts it: the key has
to be the one of the project (`4aae624e9d888fea`).

The configuration of the portal, the zone of the firewall and the service are
in the play as well — see below.

### Configuration

The play `ansible/router.yml` does it: it writes the configuration of the
portal when there is none yet, gives the tunnel a zone of the firewall, lets
the peers in from the internet, masquerades the traffic on the way out and
starts the service.

The port of the tunnel is a variable of the play: the standard port of
WireGuard by default, another one with `-e wireguard_port=...`. The play
checks it against the port the portal really listens on and stops when they
are not the same — the rule of the firewall would open a port nobody listens
on.

Where the router has a transparent proxy (podkop), the play adds the tunnel
to the interfaces of the proxy: the peers use the dns of the router, and it
answers them with the fake addresses of the proxy — without the tunnel in
the list of the proxy, their traffic to those addresses is not intercepted
and goes to the internet as it is.

The portal owns the configuration of itself: the play writes it only when
there is none, and it never touches the password of the administrator
again.

By hand, the same is:

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

The traffic of the peers is masqueraded by the zone of the wan
(`option masq '1'`) — the zone masquerades the traffic that leaves through
it. A rule of the firewall of its own for the tunnel does the opposite of
what it looks like it does: fw4 puts it into the chain of the zone of the
source, and it masquerades the traffic that goes *into* the tunnel.

Where the router has a transparent proxy (podkop), the tunnel has to be in
the interfaces of it (`source_network_interfaces`) — the peers use the dns of
the router, and it answers them with the fake addresses of the proxy.

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
