# wg-portal for OpenWrt

A ready-to-install `.apk` package of [WG Portal](https://github.com/h44z/wg-portal) for the router of
the LAN — a RouteRich AX3000 v1 (`mediatek/filogic`), `aarch64_cortex-a53`, kernel 6.12.112, 128 MB
of flash and 512 MB of RAM. The firmware of the router is OpenWrt 25.12, and OpenWrt 25.12 has `apk`
— the package manager of it is not `opkg` any more, and the packages are not `.ipk` any more.

The version of the package is **four numbers**: the three of the version of the portal (`2.3.1`) and
the fourth one is ours — it is bumped when the packaging changes.

The flash of the router is the scarce resource and the RAM is not, so the release binary of the
portal is packed with UPX: 39.4 MB → 9.9 MB in the flash, at the price of ~48 MB of RAM instead of
~31 MB — the router has 512 of them. The package is checked in an emulated OpenWrt with the very same
resources (128 MB of flash, 512 MB of RAM) before every release: the package is installed there with
apk and a real WireGuard tunnel is made through it.

Releases: <https://github.com/nhths/wg-portal-openwrt/releases> The upstream project:
<https://github.com/h44z/wg-portal>

## Install

### Through the feed

Every release carries a feed of its own: the index of the packages (`packages.adb`) and
the public key of it (`wg-portal.pem`). The index is signed with the key of the project
— an EC key of the curve P-256 — and apk checks the signature against the keys the
router trusts in `/etc/apk/keys`.

On the router:

```sh
mkdir -p /etc/apk/keys
wget -O /etc/apk/keys/wg-portal.pem https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.pem
echo 'https://github.com/nhths/wg-portal-openwrt/releases/latest/download/packages.adb' >> /etc/apk/repositories.d/customfeeds.list
apk update
apk add wg-portal
```

The url of the feed is the url of its index: a url that ends with `.adb` is taken as it
is, and the packages of the feed are taken from the same directory by their name —
`wg-portal-2.3.1.1.apk`.

The id of the key — the fingerprint of it, the one apk puts into the signature — is
`fae55c35045ee540348110e6d6487953`. The public half of the key is in the repository
([keys/wg-portal.pem](keys/wg-portal.pem)), so the key can be compared with it before it
is trusted; the sha256 of the file of it is
`c3f7c3d1651cd5d741245952d7fd533289532acff782235f1ec29184b71a9443`.

The dependency of the package — the WireGuard kernel module — apk pulls in itself from
the feeds of the firmware, so the router needs the internet.

### Through the url of the package

If the feed is not wanted, the package can be installed by its url:

```sh
apk add --allow-untrusted https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal-2.3.1.1.apk
```

The name of the asset carries the version, so the command gives one version — the one of
the url. The package is signed with the key of the project, and apk refuses to install a
package whose signature it cannot check: the key has to be trusted first (see the feed
above), and `--allow-untrusted` is the way around that. Without the feed apk cannot
update the package by itself.

### With Ansible

The play `ansible/router.yml` does the same on the LAN router: it fetches the public key
of the feed, checks it, trusts it, points apk at the feed and installs the portal from
it.

It needs the collection `community.openwrt` — the same one the check of the package
uses. Its modules are ucode scripts, and the router runs them: the router has no
Python, and it needs none.

```sh
ansible-galaxy collection install -r ansible/requirements.yml
```

Apart from that, it is the play and its vars file — the ports of the router are in
`ansible/vars/router.yml`, next to the play. Both can be fetched from the mirror and run
from the directory they are fetched into:

```sh
mkdir -p ansible/vars
curl -sSLo ansible/router.yml https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/router.yml
curl -sSLo ansible/vars/router.yml https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/vars/router.yml
ansible-playbook ansible/router.yml
```

The play fetches the public key of the feed itself, the address of the router is a
variable of it, and the inventory is not needed: the router is registered by the play.
The access is ssh as `root`, with the key of the machine the play runs on. The address of
the router is the default of the play — `192.168.0.1`. Another address, another key:

```sh
ansible-playbook router.yml -e router_address=192.168.0.2 -e router_ssh_key=~/.ssh/id_ed25519
```

The play checks the key of the feed before it trusts it: the sha256 of it has to be the
one of the project (`c3f7c3d1651cd5d741245952d7fd533289532acff782235f1ec29184b71a9443`).

## Configure

The package carries no configuration: the portal cannot run before it is written. By
hand:

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

Then the service:

```sh
/etc/init.d/wg-portal enable
/etc/init.d/wg-portal start
```

The web UI is on the port of the config.

The tunnel needs a zone of the firewall of its own — by **device**, not by network (the
interface is created by the portal itself and is not in `/etc/config/network`), and the
traffic of the peers has to be masqueraded on the way out. The play `ansible/router.yml`
does all of it; the details are in [AGENTS.md](AGENTS.md).

## Update

With the feed in place, apk sees the new versions:

```sh
apk update
apk upgrade wg-portal
```

`apk add` does not upgrade a package that is installed already — the upgrade is
`apk upgrade`, and it prints what it did
(`(1/1) Upgrading wg-portal (2.3.1.1 -> 2.3.1.2)`). The router can do it on its own,
once a night, for example:

```sh
echo '0 4 * * * apk update && apk upgrade wg-portal >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart
```

The play does the same: run it again and the portal is upgraded to the version of the
feed, and the service is restarted when the binary of it changed.

## Build

Docker with network access is required. The measurements and the checks additionally
need `qemu-system-aarch64`; the WireGuard check needs root (it creates a tap device) and
`ethtool`.

```sh
make dist           # download, pack with UPX, build the .apk and sign it
make feed           # build the index of the feed and sign it
make check-install  # install the .apk in an emulated OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
```

`ARCH` is the exact value of the architecture of the router (`aarch64_cortex-a53`); apk
refuses the package otherwise. `PKG_REV` is the fourth number of the version of the
package — it is bumped when the packaging changes.

`make dist` and `make feed` sign the package and the index of the feed with the secret
key of the project. The secret key is not in the repository: it lives in
`~/.config/wg-portal/secret.pem` for the local runs and in the secrets of the CI
(`APK_SECRET_KEY`) for the releases. The public key is in the repository. The details —
the layout of the project, the emulation, the checks, the release workflow and the notes
of the measurements — are in [AGENTS.md](AGENTS.md).
