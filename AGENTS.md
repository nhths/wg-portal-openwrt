# AGENTS.md

The working notes of the project: how the package of
[WG Portal](https://github.com/h44z/wg-portal) is built, how the check
works, and what is known about the router it is built for.

The README is the short version — what the thing is, how to install it, how
to build it. This file is everything else.

## The rules of the project

- The files that go into the router or into the package are templates in
  `templates/`, rendered with Jinja2 — one template syntax in the project,
  and every file can be read on its own. The router is configured by
  Ansible (it renders the templates on the controller), the package by the
  script that builds it.
- The packaging is a script (`scripts/build-apk.sh`), not a play.
- The real router is only ever touched through the play `ansible/router.yml`
  — never by hand over ssh. Everything else runs in the emulated guest. The
  play is written for the user, who runs it, and it was run against the
  router on the user's request: the firewall of the tunnel, the configuration
  of the portal and the service.
- Everything in the repository is in English.
- `ARCH` is the exact value of the architecture of the router
  (`aarch64_cortex-a53`); apk refuses the package otherwise.
- The build artifacts are not tracked — see `.gitignore`.
- The secret key of the feed of the portal is never in the repository: only
  the public half is (`keys/wg-portal.pem`). The secret half is in the
  secrets of the CI (`APK_SECRET_KEY`) and in `~/.config/wg-portal/secret.pem`
  locally.

## The layout

```text
README.md                    what the thing is, how to install it, how to build it
AGENTS.md                    this file
Makefile                     the entry points
Dockerfile                   the image of the WireGuard check
Dockerfile.builder           the image that builds wg-portal from source
Dockerfile.pkg               the toolbox of the package: UPX, the apk-tools,
                             Jinja2
.github/workflows/
  wg-portal-release.yml      the workflow of the release: the portal is checked
                             for updates every two weeks
keys/
  wg-portal.pem              the public key of the feed of the portal
ansible/
  site.yml                   the OpenWrt setup of the emulated router
  router.yml                 the feed of the portal on the real router
  inventory.ini              the emulated router is registered by the play
  ansible.cfg
  requirements.yml           the collections the play needs
  vars/main.yml              the defaults of the check
  vars/router.yml            the ports of the real router
  roles/opwrt/tasks/         the setup: the feed, the portal, the service
  roles/tunnel/tasks/        the guest side of the check
  roles/package/tasks/       the checks of the installation of the package
templates/
  apk/                       the files of the package: the metadata, the init
                             script, the scripts of the package
  openwrt/                   the network of the guest, the config of the portal
scripts/
  build-apk.sh               download → UPX → build the .apk
  build-src.sh               build wg-portal from source and compare sizes
  check.sh                   the checks: the package, the WireGuard tunnel
  guest.sh                   the emulated router: fetch, boot, flash
  make-feed.sh               the index of the feed of the portal
  bench.sh                   measure in an emulated arm64 guest
  bench-init.sh              the init of the measurement guest
  bench-one.sh               measure one binary: the startup time and the RSS
  portal-api.py              drive the portal API: interface, peer, config
wg-portal-upx-ipk-bench.md   the original task brief
```

## The targets

```sh
make dist           # download, pack with UPX, build the .apk and sign it
make feed           # the index of the feed of the portal and the signature of it
make bench          # measure size, startup time and RAM in an emulated guest
make check-install  # install the .apk in a guest OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
make build-src      # build wg-portal from source and compare the sizes
make lint           # shellcheck + ansible-lint + markdownlint
```

Docker with network access is required. The measurements and the checks need
`qemu-system-aarch64`; the WireGuard check needs root (it creates a tap
device) and `ethtool`.

The variables of the Makefile: `VER` (the version of the portal, `v2.3.1`),
`PKG_REV` (the fourth number of the version of the package, `1`), `ARCH`
(`aarch64_cortex-a53`), `IMAGE`, `PKG_IMAGE`, `TAG`, `DOCKER` (`docker` or
`podman`) and `SECRET_KEY` (the secret half of the key of the feed).

## The build of the package

`make dist` builds the toolbox image (`Dockerfile.pkg`) and runs it:
`scripts/build-apk.sh` downloads the release binary of the portal, packs it
with UPX, renders the files of the package from `templates/apk/` and
assembles the `.apk` with `apk mkpkg`.

The toolbox is Debian, because the busybox tar of Alpine does not know the
options the package needs (`--numeric-owner`, `--owner`, `--group`).

The apk-tools are taken from the ready-made package of Alpine: the static
build, 3.0.9. The format of the packages and of the indexes is the one of
apk 3.0.x — the same the OpenWrt 25.12 uses (3.0.5); the header of the
schema (`apk_adb.h`) is byte for byte the same in both, the differences
between them are in the checks of the values.

The package carries the metadata of the package (`templates/apk/metadata.j2`:
the name, the version, the architecture, the description, the license, the
maintainer, the url, the origin and the dependency on `kmod-wireguard`), the
binary in `usr/bin/wg-portal` (755), the init script in `etc/init.d/`
(755) and the list of the files in `lib/apk/packages/wg-portal.list` — the
list OpenWrt reads in the scripts of the packages.

The scripts of the package are the ones of OpenWrt: `post-install` and
`post-upgrade` enable the service, `pre-deinstall` stops it and disables it.
The service is enabled but not started: the package carries no configuration
of the portal, and it cannot run before it is written.

**The package is signed.** apk refuses to install a package whose signature
it cannot check, and it refuses to build an index from one either — so the
secret key of the project is needed to build the package at all
(`apk mkpkg --sign-key`). The secret half is not in the repository: it is in
the secrets of the CI (`APK_SECRET_KEY`) and in `~/.config/wg-portal/secret.pem`
locally.

The container of the toolbox runs as **root**, and it has to: the files of
the package belong to root, as the files of every package of OpenWrt do
(`a:0:0:755` in the database of the firmware). A package built by a user
records `nobody:nobody` instead — apk knows no name for the uid of the
builder.

The artifacts of the build in `dist/` belong to the user of the host: the
container gets the ids of it (`HOST_UID`, `HOST_GID`) and gives the files
back to it at the end. Rootless podman maps the ids of the users its own
way and needs `--userns=keep-id` for that; the root of the host is mapped
to itself anyway, and the runner of the CI builds with podman as root. The
Makefile adds the flag when it is needed and only then.

The configuration of the portal is not in the package: the init script points
the binary at `/etc/wg-portal/config.yaml`, and the file has to be written on
the router. The keys of it are the sections of the configuration of the
portal — `core.admin_password`, `web.listening_address` and `database.dsn`
(the same names the environment variables `WG_PORTAL_CORE_ADMIN_PASSWORD` and
friends are built from). If the file should not be required at all, drop the
`procd_set_param env` line in `templates/apk/init.d.j2`.

## The compression

Only one mode is used: **`upx --best --lzma`**. The packed binary is
verified with `upx -t`.

Measured on v2.3.1 / linux-arm64 with UPX 4.2.4:

| Mode | Size | Ratio |
| --- | --- | --- |
| original | 41 353 378 B (39.4 MB) | 100 % |
| `--best` (NRV2E) | 14 119 956 B (13.5 MB) | 34.1 % |
| `--lzma` | 10 440 828 B (10.0 MB) | 25.3 % |
| **`--best --lzma`** | **10 371 636 B (9.9 MB)** | **25.1 %** |

LZMA beats NRV2E by almost 3 MB, and `--best` on top of LZMA saves another
70 kB. The two other modes are not kept: they only waste space.

The packing is the right trade for the router, because of its resources:
**128 MB of flash and 512 MB of RAM**. The flash is the scarce one — the
unpacked binary would take 39.4 MB of it — and the RAM is not: the packed
binary needs ~48 MB of it instead of ~31 MB, and the router has 512 MB.

## The measurements

`make bench` measures the size, the startup time and the memory of the
binary in an emulated arm64 guest (`scripts/bench.sh` boots the guest,
`scripts/bench-one.sh` measures one binary, `scripts/bench-init.sh` is the
init of the guest).

### arm64, full system emulation (qemu-system-aarch64, Alpine 3.21 guest)

| Variant | Size | Startup | VmHWM | VmRSS |
| --- | --- | --- | --- | --- |
| `orig` | 41 353 378 B (39.4 MB) | 2.66 s | 30.7 MB | 30.7 MB |
| `--best` | 14 119 956 B (13.5 MB) | 5.59 s | 52.7 MB | 47.7 MB |
| `--lzma` | 10 440 828 B (10.0 MB) | 8.08 s | 49.2 MB | 47.7 MB |
| `--best --lzma` | 10 371 636 B (9.9 MB) | 7.98 s | 49.2 MB | 47.7 MB |

All four variants report `STATUS=OK`: the binary unpacks, starts and answers
HTTP on `127.0.0.1:8888`.

### amd64, native container (control run)

| Variant | Size | Startup | VmHWM | VmRSS |
| --- | --- | --- | --- | --- |
| `orig` | 43 237 538 B (41.2 MB) | 0.32 s | 34.9 MB | 34.9 MB |
| `--best` | 15 583 964 B (14.9 MB) | 0.55 s | 56.0 MB | 54.2 MB |
| `--lzma` | 11 997 600 B (11.4 MB) | 1.02 s | 54.3 MB | 54.3 MB |
| `--best --lzma` | 11 914 616 B (11.4 MB) | 1.03 s | 52.5 MB | 52.2 MB |

### What the numbers mean

- **Size**: UPX saves 74 % (39.4 → 9.9 MB).
- **Startup**: the unpacking costs 3–5 s on a slow emulation — less on real
  hardware, but the same order of magnitude. For a web UI that is started
  once a day it does not matter.
- **RAM**: the unpacked image ends up in anonymous memory, so RSS grows from
  30.7 MB to ~48 MB, i.e. **+55 %**.

The router has **128 MB of flash and 512 MB of RAM**: the flash is the scarce
resource and the RAM is not. So the packed binary is the right one — it
gives back 29.5 MB of the flash for 17 MB of the RAM, and the router has
more than ten times the RAM the packed binary needs. Every packed mode needs
about the same amount of RAM, so the mode is chosen by the size alone:
`--best --lzma`. `--best` costs 3.6 MB more flash and starts ~2.4 s faster,
but needs the same RAM — take it only when the flash is tight or the startup
matters.

The absolute numbers are only meaningful within one round: the emulation is
CPU-bound and the first binary started in a guest pays the warm-up of the
translation cache (~0.4 s). Re-running the same guest on a loaded host
shifts the startup time of the packed variants by seconds.

### The size of the source build

The release binary is already stripped (`-ldflags "-w -s"`), and rebuilding
from source with the same flags gives a binary of the same size — the
release is reproduced:

| Build | Size |
| --- | --- |
| release binary v2.3.1 | 41 353 378 B (39.4 MB) |
| source build, upstream flags | 41 353 378 B (39.4 MB) |
| + trimmed assets | 36 831 394 B (35.1 MB) |

So upstream builds exactly `-ldflags "-w -s -extldflags '-static'" -tags
netgo`, and a rebuild on its own does not shrink anything. The real levers:

1. **The dead assets** — the binary embeds the FontAwesome fonts (3.9 MB) in
   every format: `eot`, `svg`, `ttf`, `woff`, `woff2`. Modern browsers need
   only `woff2`/`woff` — the rest (~2.2 MB) need not be embedded. Plus
   `assets/doc/*` (swagger json/yaml, 278 kB) and
   `assets/js/rapidoc-min.js` (843 kB) — the API documentation page.
   Together −4.5 MB (−11 %).
2. **The frontend itself** — vite builds `index.js` to 1.86 MB and
   `index.css` to 646 kB, plus ~1.5 MB of SVG flags for the country selector
   in i18n.
3. **The Go dependencies** — the bulk of it (gin, gorm, ldap, oidc,
   sqlite). These can only be reduced by cutting features, i.e. by changing
   code, not by build flags.

A rebuild is worth it only when custom changes are needed (version, default
config, trimmed assets) — then the size can go down to ~35 MB before UPX
and ~9 MB after.

## The emulated router

Both checks run the same machine: the stock OpenWrt 25.12.6 arm64 rootfs on
a 128 MB ext4 flash with 512 MB of RAM — exactly the resources of the real
router (RouteRich AX3000 v1: 128 MB of flash, 512 MB of RAM). The measured
memory of the packed binary is therefore the memory it takes on the router.
The flash is built with `mke2fs -d` (`scripts/guest.sh flash`), attached as a
virtio disk, and the guest boots from it directly with the kernel of the
release.

The guest is a real OpenWrt: it boots with its own `init` (procd), so the
services of the packages work as they do on the router. Two things are baked
into the flash, because Ansible needs them to get in at all:

- the address of the guest (`/etc/config/network`) — the tap between the host
  and the guest has no DHCP server; the file is rendered from
  `templates/openwrt/network.j2` into the rootfs before the flash is built;
- the key Ansible logs in with (`/etc/dropbear/authorized_keys`).

The WireGuard modules come from the OpenWrt repository, not from the image:
`kmod-wireguard`, the crypto modules it needs and `kmod-udptunnel4` /
`kmod-udptunnel6`. Their feed is the index of apk v3 (`packages.adb`), signed
with the key of the firmware — the guest trusts that key out of the box
(`/etc/apk/keys/openwrt-25.12.pem` of the rootfs).

The measurements need a real guest kernel: under `qemu-user` the call
`socket(AF_NETLINK, …, NETLINK_GENERIC)` returns `EPROTONOSUPPORT`, so
wg-portal cannot create its WireGuard controller and refuses to start.

## The setup of the guest, by Ansible

`ansible/` converges the OpenWrt guest over SSH with the same collection the
LAN router is converged with (`community.openwrt`): its modules are ucode
scripts, so the guest needs no Python. The collection is installed with
`ansible-galaxy collection install -r ansible/requirements.yml`.

The play is run by the check in three steps, because the network of the
guest has to be in the flash before it boots, the guest has to be up before
the portal can be started and the client has to be up before the tunnel can
be checked:

```sh
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags net \
  -e @/tmp/wgp-vm/vars.json
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags setup \
  -e @/tmp/wgp-vm/vars.json
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags verify \
  -e @/tmp/wgp-vm/vars.json
```

- `net` writes `/etc/config/network` into the rootfs of the guest, on the
  controller — the router is not up yet.
- `setup` installs the `.apk` of the portal with apk, loads the WireGuard
  modules, writes `/etc/wg-portal/config.yaml` and starts the service.
- `verify` waits for the traffic in the tunnel and pings the client back
  from the guest.
- `package` holds the checks of the installation and the removal of the
  package.

The values of the emulated router are passed in by the harness with
`-e @/tmp/wgp-vm/vars.json` as `wgp_overrides` and merged into the defaults
of `ansible/vars/main.yml`.

The files the play writes are rendered from `templates/openwrt/` — the
configuration of the portal is `templates/openwrt/config.yaml.j2`, and the
`community.openwrt.template` module renders it on the controller and copies
the result to the guest.

## The dependency of the portal

The portal depends on `kmod-wireguard`, and the check does not install that
module by hand: apk has to resolve the dependency itself, the way it does
on the router. The modules come from a feed — the index of the OpenWrt
repository, signed with the key of the firmware, and the packages themselves
— which the host serves over HTTP to the guest.

The feed of the check serves the whole chain of the dependencies of
`kmod-wireguard`: `kmod-crypto-lib-curve25519`,
`kmod-crypto-lib-chacha20poly1305`, `kmod-crypto-lib-chacha20`,
`kmod-crypto-lib-poly1305`, `kmod-crypto-hash`, `kmod-crypto-kpp`,
`kmod-udptunnel4` and `kmod-udptunnel6` — apk downloads the ones it needs by
itself. The versions of them are taken from `index.json` of the feed, and
the name of a package of apk v3 is its name and its version:
`kmod-wireguard-6.12.112-r1.apk`.

The install of the portal looks like this in the log of the check:

```text
(1/9) Installing kmod-crypto-lib-chacha20 (6.12.112-r1)
  Executing kmod-crypto-lib-chacha20-6.12.112-r1.post-install
...
(8/9) Installing kmod-wireguard (6.12.112-r1)
  Executing kmod-wireguard-6.12.112-r1.post-install
(9/9) Installing wg-portal (2.3.1.1)
  Executing wg-portal-2.3.1.1.post-install
OK: 24.6 MiB in 214 packages
```

### The quirks of apk

- The url of a feed is the url of its **index**: a url that ends with
  `.adb` is taken as it is, and the packages of the feed are taken from the
  same directory by their name. A url that does not end with `.adb` is the
  url of a v2 repository, and apk looks for `APKINDEX.tar.gz` in it.
- The architecture list comes from `/etc/apk/arch` — one architecture per
  line. The guest is `aarch64_generic` and the package is built for
  `aarch64_cortex-a53` (the architecture of the router), so the role writes
  both of them into the file.
- A package whose signature apk cannot check is not installed at all, and
  an index cannot be built from one either. The signature is inside the
  file, and the key it is made with is identified by its id — the first 16
  bytes of the sha512 of the public point of the key.
- `apk add` does not upgrade a package that is installed already: it says
  nothing and keeps the old version. The upgrade is `apk upgrade <name>`,
  and it prints what it did: `(1/1) Upgrading wg-portal (2.3.1.1 ->
  2.3.1.2)`. The module `community.openwrt.apk` does not upgrade either —
  it asks apk about the package first and does nothing when it is there.
- The scripts of a package are run by apk with an environment of its own,
  and nothing else:

  ```text
  APK_PACKAGE=wg-portal
  APK_SCRIPT=post-install
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  PWD=/
  ```

  `IPKG_INSTROOT` — the variable of opkg, the one the scripts of OpenWrt
  use — is **not** set by apk: it is empty on the device.
- OpenWrt has its own hooks for its packages: `default_postinst` and
  `default_prerm` in `/lib/functions.sh`. They find the init scripts of the
  package in `/lib/apk/packages/<name>.list`, and `default_postinst`
  enables **and starts** them. The portal is not one of them: it needs the
  configuration of it, which is written on the router. The package has
  hooks of its own — they enable the service and do not start it.

## The feed of the portal

A package installed by its url is in no feed, so apk cannot update it: it
knows the version that is installed and nothing else. The feed is what makes
the update possible — it is the index of the packages and the packages
themselves.

The index of a feed of apk v3 is `packages.adb` — the database of apk, in
the binary format of ADB. It is built by apk itself (`apk mkndx`), and it
carries the metadata of every package of the feed. `apk adbdump` prints it
in a readable form:

```text
#%SCHEMA: 78646E69
# ADB block, size: 212, compat: 0, ver: 0
description: the feed of the portal for the router of the LAN
packages: # 1 items
  - name: wg-portal
    version: 2.3.1.1
    hashes: ...
    description: WireGuard Portal - web UI for WireGuard
    arch: aarch64_cortex-a53
    license: MIT
    origin: https://github.com/h44z/wg-portal
    depends: kmod-wireguard
    installed-size: ...
# sig v00 h04 ...: OK
```

The last line is the signature of the index: `OK` means that it is made with
a key the reader trusts.

The index is built from the package that is already signed: apk refuses to
index a package whose signature it cannot check, and the keys of the feed
are the ones it checks it against (`--keys-dir`).

### The signature

The signature is made with the key of the project — an EC key of the curve
P-256, the same kind the firmware of OpenWrt signs its own feeds with. The
public key is in the repository
([keys/wg-portal.pem](keys/wg-portal.pem)), the secret half is not: it is in
the secrets of the CI (`APK_SECRET_KEY`) and, for the local runs, in
`~/.config/wg-portal/secret.pem`.

The id of the key — the fingerprint of it, the one apk puts into the
signature — is `fae55c35045ee540348110e6d6487953`. It is the first 16 bytes
of the sha512 of the public point of the key, not of the file of it:

```sh
openssl pkey -pubin -in keys/wg-portal.pem -outform DER | tail -c 65 | sha512sum | cut -c1-32
```

```sh
make feed                       # the index and the signature of it
make feed SECRET_KEY=/somewhere/secret.pem
```

The signing is done by the apk-tools of the toolbox image: the index is
signed while it is built (`apk mkndx --sign-key`), there is no separate step
for it.

### The feed of the check

The check serves the feed of the project itself: the index and the package
are the ones of the release (`make feed` builds them), and the guest is
given the public key of the project. The chain the check proves is the
chain the router of the LAN goes through — the same index, the same key,
the same signature.

The check serves the feed on the second port (18081), next to the port of
the feed of the firmware (18080): the guest has two feeds, the packages of
the portal come from one, the kernel modules from the other.

### The feed of the release

Every release publishes the index of the feed next to the package:
`packages.adb` and `wg-portal.pem`. The url of the feed is the url of the
index:

```text
https://github.com/nhths/wg-portal-openwrt/releases/latest/download/packages.adb
```

The name of the package carries the version — apk takes it from the name and
the version of the package in the index — so the asset of the release is
`wg-portal-2.3.1.1.apk`, and the url of it is the url of the feed with the
name of the package at the end.

### The play for the router

`ansible/router.yml` installs the feed on the real router: it fetches the
public key of the feed, checks it, trusts it with the module
`community.openwrt.apk_feed` and installs the portal from it with
`community.openwrt.apk`. It is the same chain the check of the emulated guest
goes through, only on the device.

The play needs the community.openwrt collection — the same one the check of the
guest uses:

```sh
ansible-galaxy collection install -r ansible/requirements.yml
```

Its modules are ucode scripts, and the router runs them: the router has no
Python, and it needs none — `ucode` and `rpcd` are in the firmware of it.

Apart from that, the play needs nothing but the access to the router:

- the public key it fetches itself, from the release;
- the address of the router is a variable of the play (`router_address`), and
  the key of it is another one (`router_ssh_key`, empty means the default key
  of the machine);
- the inventory is not needed: the router is registered by the play itself
  (`add_host`). If the inventory has a host named `router`, that one is used
  as it is.

```sh
ansible-playbook ansible/router.yml
```

The play and its vars file are the two files of it: the ports of the router
are in `ansible/vars/router.yml`, and the vars of a play are loaded from the
directory of the playbook. Both are fetched from the mirror and run from the
directory they are fetched into:

```sh
mkdir -p ansible/vars
curl -sSLo ansible/router.yml https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/router.yml
curl -sSLo ansible/vars/router.yml https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/vars/router.yml
ansible-playbook ansible/router.yml
```

The key of the feed is checked before it is trusted: the sha256 of it has to
be the one of the project
(`c3f7c3d1651cd5d741245952d7fd533289532acff782235f1ec29184b71a9443`).

The session of dropbear needs the keepalive of the client as well: it drops
a session that receives nothing for 300 seconds (`-K 300`), and it counts the
packets it reads. The `ServerAliveInterval` of the ssh settings keeps the
session alive while the package is downloaded.

The configuration of the portal, the zone of the firewall and the service are
in the play as well: it writes the configuration of the portal when there is
none yet, puts the tunnel into the firewall — the zone by device, the
forwardings in both directions, the rule of the wan and the masquerade of the
traffic of the tunnel — and starts the service.

The ports are in `ansible/vars/router.yml`: the web interface of the portal
and the tunnel. The port of the tunnel is the standard port of WireGuard by
default, another one with `-e wireguard_port=...`. The play reads the port
the portal really listens on from the configuration it writes for the
interface (`{{ advanced.config_storage_path }}/<interface>.conf`) and stops
when it is not the port of the variables: the rule of the firewall would open
a port nobody listens on.

The play was run against the router on 2026-11-07 — with the opkg
packaging of that time; the portal was installed and started. The apk
packaging was checked against the emulated guest instead: the same device,
the same OpenWrt, with the feed of the check instead of the one of the
release. Both ways were checked — the file of the repository and the play
piped from the mirror.

## The checks

`scripts/check.sh` boots the emulated router and has two modes:

- `install` — the package: the files apk made of it, the service it enabled,
  the binary that answers HTTP, and that the package can be taken away again
  and installed once more.
- `wireguard` — the whole chain: the portal manages a real WireGuard server
  interface, a client connects with the configuration the portal hands out and
  pings through the tunnel, and the guest pings the client back.

```sh
./scripts/check.sh install     # on the host
make check-wireguard           # the same, but in the image of the check
```

The install check prints what apk made of the package:

```text
wg-portal-2.3.1.1 description:
WireGuard Portal - web UI for WireGuard

wg-portal-2.3.1.1 installed size:
9 MiB

wg-portal-2.3.1.1 contains:
etc/init.d/wg-portal
lib/apk/packages/wg-portal.list
usr/bin/wg-portal

lrwxrwxrwx 1 root root 19 Nov  8 12:52 K01wg-portal -> ../init.d/wg-portal
lrwxrwxrwx 1 root root 19 Nov  8 12:52 S99wg-portal -> ../init.d/wg-portal
```

After the install the packaged binary answers HTTP (the RSS of it is ~46 MB,
the HWM ~50 MB — the packed binary, see "The compression"), and `apk del
wg-portal` takes the package away again. The check installs it once more
after that.

The `K01` link is made by apk itself, the `S99` one by the init script of the
package (`START=99`).

### The image of the check

`make check-wireguard` runs the check in its own image: the emulated router
with the portal inside and the WireGuard client next to it, in one container.

```sh
docker build -t wg-portal-check .
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN --cap-add NET_RAW \
  wg-portal-check
```

The container needs the tun device (`--device /dev/net/tun`) and the right to
create the network interfaces in its namespace (`--cap-add NET_ADMIN`): the
tap between the host and the guest and the WireGuard interface of the client
are both created there. It needs the raw socket as well (`--cap-add
NET_RAW`): the ping of the client through the tunnel is an `iputils-ping`,
which opens a raw socket — docker gives the capability by default, podman
does not, and without it the ping fails with "ping: Operation not permitted"
on the standard error, where the log of the check does not show it. The image
brings QEMU, the WireGuard tools, the guest (the rootfs, the kernel and the
kernel modules), the keys of the feed, the package and the index of the feed
— and Ansible with the collection. The check itself needs no network.

The tun device is a device of the machine the container runs on: the `tun`
module has to be loaded there (`modprobe tun`). The runner of the group does
not have it yet, so the check job of the pipeline fails there with
`stat /dev/net/tun: no such file or directory` — that is why the job is
manual: the build job stays the blocking one.

### The network of the check

```text
host (wg-test, 10.99.0.2) ──WireGuard──▶ router (wg0, 10.99.0.1)
   10.77.0.1 ──────────tap──────────▶ 10.77.0.2
```

The client cannot live in the same network namespace as the server: the
address of the server interface is a local address there, so the traffic
never enters the tunnel. The client is therefore on the host.

The two are connected by a tap device, not by the user-mode network of QEMU:
slirp rewrites the UDP endpoints of the forwarded ports, and a WireGuard peer
accepts the handshake response only from the address it sent the request to.
Over the user-mode network the guest receives the handshake, answers it, and
the answer is lost on the way back.

The offloads of the tap have to be off (`ethtool -K tap tso off gso off gro
off tx off sg off`): the guest does not understand the checksum and
segmentation offload of the tap and drops the packets.

The addresses of the tunnel (`10.99.0.1` and `10.99.0.2` here) have to be
free on the host. An address that is local there makes the answers of the
router arrive with a source address that is local as well, and the host
drops them as a martian source — the tunnel carries the traffic and nothing
answers. The check says so and stops instead of failing silently; the image
of the check has its own network namespace and is not affected.

### What the WireGuard check does

1. boots the emulated router and lets Ansible set it up (the packages, the
   modules, the configuration, the service);
2. creates the interface `wg0` (server mode, port 51820) and a peer through
   the API — the same API the web UI talks to (`scripts/portal-api.py`);
3. takes the configuration the portal returns and brings the client up with
   it;
4. pings 10.99.0.1 through the tunnel, and the guest pings the client back;
   the counters of the interface inside the guest show the traffic.

The result is `WG_STATUS=OK`:

```text
=== verifying the tunnel from the guest
TUNNEL_PING=OK
TUNNEL_TRAFFIC 564 476
=== pinging through the tunnel
PING 10.99.0.1 (10.99.0.1) from 10.99.0.2 wg-test: 56(84) bytes of data.
64 bytes from 10.99.0.1: icmp_seq=1 ttl=64 time=2.26 ms
...
3 packets transmitted, 3 received, 0% packet loss, time 2002ms
WG_STATUS=OK
```

The API of the portal encodes every id: base64 with `=` → `-`, `/` → `_`,
`+` → `.` (the interface id in the peer paths is encoded the same way). The
peer model wraps its configurable values (`Endpoint`, `AllowedIPs`, `Dns`, …)
into `{"Value": …, "Overridable": …}` — a plain string is rejected. Both are
handled in `scripts/portal-api.py`.

The peer configuration the portal hands out carries the allowed IPs of the
*peer* (`10.99.0.0/24` here). The client routes that network into the
tunnel, the server uses it to check the source address of the packets.

### The firewall of the router

The guest is a stock OpenWrt, so it has a firewall (fw4) with the default
policy `input REJECT`. The interface of the portal belongs to no zone of it,
and the traffic of a peer is not tracked by the connection tracking: without
a zone of its own, the echo request of the peer is rejected and the peer
gets an "unreachable" instead of the answer.

The zone has to name the **device**, not a network:

```text
config zone
        option name 'wg'
        list device 'wg0'
        option input 'ACCEPT'
```

`list network 'wg0'` does not work: the interface of the portal is created by
the portal itself and is not in `/etc/config/network`, so a network of that
name never matches any traffic — the zone stays empty and the traffic of the
peer keeps hitting the default policy.

The zone alone is not enough: the tunnel has to be let out to the lan and to
the wan and in from the lan, the port of the tunnel has to be open on the
wan, and the traffic of the peers has to be masqueraded on the way out — the
addresses of the tunnel are not routable outside of the LAN. The play makes
all of it:

```text
config forwarding
        option src 'wg'
        option dest 'lan'

config forwarding
        option src 'wg'
        option dest 'wan'

config forwarding
        option src 'lan'
        option dest 'wg'

config rule
        option name 'Allow-WireGuard'
        option src 'wan'
        option proto 'udp'
        option dest_port '62820'
        option target 'ACCEPT'
```

The masquerade of the traffic on the way out is the `masq` of the zone of
the wan — the zone masquerades the traffic that leaves through it. A rule of
the firewall of its own for the tunnel does the opposite of what it looks
like it does: fw4 puts such a rule into the chain of the zone of the
**source**, and that chain is entered by the traffic that leaves through the
zone — so it masquerades the traffic that goes *into* the tunnel, and the
peers never answer the ping of the portal.

The port of the rule of the wan is the port of the variables of the play,
and it is checked against the port the portal writes for the interface.

The public address of the router is the address of the services of the
gateway, and the firewall of the router redirects the traffic of the wan
zone to them. The traffic of the tunnel is not redirected by that: it is
delivered to the router itself, and the router answers it with the
certificate of its own web interface (uhttpd, the OpenWrt one) instead of
the certificate of the gateway.

fw4 builds the rules of the hairpin of the lan on its own: the clients of
the lan reach the public address of the router through the gateway too, and
the traffic is masqueraded to the lan address of the router on the way
back. Those rules match the network of the lan, so the peers of the tunnel
are not covered by them — and a redirect of the zone of the tunnel on its
own would match by the port alone, and then every request of the peers
would go to the gateway, the traffic to the other sites and to the gateway
alike.

The play puts the zone of the tunnel into the reflection of the redirects of
the wan zone (`reflection_zone`), and it gives the zone of the tunnel the
network of the interface (`option subnet`) — fw4 needs the addresses of the
peers for the rules of the reflection. The rules of the tunnel are then the
rules of the hairpin of the lan, and they match the public address of the
router as well:

```text
chain dstnat_wg {
        ip saddr 172.26.0.0/24 ip daddr 94.19.182.96 tcp dport 443 dnat 192.168.31.98:443
}
```

The masquerade of the way back is a rule of its own (`<name>_wg_snat`): the
rules of the reflection masquerade the traffic to the lan address of the
router, but they land in the chain of the zone of the tunnel — and the
traffic of the peers leaves through the lan, so they never apply to it. The
rule of the play does it for the peers: the gateway answers to the router.

The rule is a section of the type `nat` and not a redirect with the target
`SNAT`. LuCI nags about the second form on every page of the firewall until
it is migrated, and the migration is LuCI's business — the play has to
leave the router in the form LuCI wants. fw4 puts the rule of a `nat` into
the chain of the zone of its **source** — the zone the traffic leaves
through — and that is the lan, where the peers' traffic goes:

```text
chain srcnat_lan {
        ip saddr 172.26.0.0/24 ip daddr 192.168.31.98 tcp dport 443 snat ip to 192.168.31.1
}
```

The section is found by its name and not created by it: a section that
LuCI has migrated already carries that name, and the play has to change it
in place instead of adding a second one. The old form is taken away by the
same name, so that the rule of the `nat` is the only one.

### The proxy of the router

The router has a transparent proxy on it (podkop), and the traffic of the
lan goes through it: the dns of the router answers with the fake addresses
of the proxy (198.18.0.0/15), and the proxy intercepts the traffic to them
with the mark `0x100000` and a tproxy to itself.

The tunnel has to be in the list of the interfaces of the proxy
(`source_network_interfaces`), or the peers get the same fake addresses and
their traffic to them is not intercepted: it goes to the internet as it is,
and nobody answers it. The play adds the interface to the list and restarts
the proxy — when the router has a proxy at all: the play looks for the config
and the service of it first, and leaves the router alone when there is none.

### The routing of the router

The portal does not put the route of the peer into the main table. It gives
the interface a firewall mark, puts the route of the peer into a table with
the number of that mark and adds a rule that sends the marked traffic there:

```text
10.99.0.2 dev wg0 table 20003 scope link
0:      from all lookup local
32700:  from all fwmark 0x4e23 lookup 20003
32766:  from all lookup main
```

The mask of the rule is empty, so it matches every packet, and the lookups of
the guest find the route of the peer. The mark itself is never needed: the
WireGuard module marks the encapsulated packets, not the plaintext ones.

### The allowed IPs of the peers

The allowed IPs of a peer are the addresses the server routes **to** that
peer, and the portal writes them into the configuration of the interface. The
module of WireGuard uses them twice: it picks the peer of a packet by its
destination address, and it checks the source address of every decrypted
packet against them — a packet whose source is not in them is dropped.

Three things follow from that, and all of them were seen on the router:

- The address of the peer itself is enough for a peer that reaches the
  internet: its traffic is masqueraded by the firewall of the wan and comes
  back to it by the route of the portal.
- A peer that reaches the **lan** needs the network of the lan in its allowed
  IPs — the source address of the packet of the lan client is not in the
  address of the peer otherwise, and the module drops the packet. The client
  has to route the network of the lan into the tunnel as well; its own
  configuration is made by the portal.
- Two peers with the **same** network in their allowed IPs shadow each other:
  the trie of the module keeps one peer per prefix, and the traffic of one of
  them is delivered to the other. The prefix of a peer is its network, so
  `172.26.0.2/24` and `172.26.0.4/24` are the same prefix — `172.26.0.0/24` —
  and only one of the two peers ever receives the traffic of the network.

The address of the interface of the portal is the network itself
(`172.26.0.0/24`): the network address is not a valid source address, so the
router cannot originate the traffic to the peers by itself, and the ping of
the portal to its peers fails for that reason.

## The workflow of the release

`.github/workflows/wg-portal-release.yml` is a GitHub Actions workflow. Every
two weeks (the 1st and the 15th of the month) it looks for a new release of
the portal (`h44z/wg-portal`). If there is one, it builds the package, checks
it in the emulated OpenWrt — the same check as `make check-wireguard` — and
publishes the `.apk` as a release of the repository.

The state of the workflow is the release itself: if the version of the portal
is already released here, the run does nothing. The run can also be started
by hand (`workflow_dispatch`), with the version of the portal as the
argument.

The tag of the release is the version of the package — the three numbers of
the version of the portal and the fourth one, the revision of the packaging.
The run looks at the tag of the last release here: the three first numbers
of it are the version of the portal, and if they are the same — the version
of the portal is already released — the run does nothing.

The name of the asset of the package carries the version:
`wg-portal-2.3.1.1.apk`. The url of it is therefore the url of one version,
and apk takes the version of the package from the name of the file:

```sh
apk add --allow-untrusted https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal-2.3.1.1.apk
```

The release carries the feed of the portal as well (see "The feed of the
portal"): the index of it (`packages.adb`) and the public key of it
(`wg-portal.pem`).

The workflow signs the package and the index with the secret key from the
secrets of the repository (`APK_SECRET_KEY`) and checks the signature of the
index against the public key of the repository afterwards — a secret that
does not belong to that key fails the release. Both are built by `make dist`
and `make feed`: the package is signed while it is built, and the index is
signed while it is built too.

The workflow runs the code of the repository it is in, so the GitHub copy of
the project is the one the Actions run in; the GitLab repository is the source
of truth.

Two things to know about the scheduled runs: GitHub delays them (a run can
start an hour after its time), and it stops them altogether if the repository
has no activity for 60 days — a commit or a manual run brings them back.

### The quirks of GitHub Actions

- A workflow that is added in the **first push** of a new repository is not
  indexed by GitHub (the repository is still being provisioned): the file is
  there, but it is not in the list of the workflows. Any change of the file
  fixes it — that is why the workflow has a `push` trigger on its own path.
  The check is `gh workflow list`; the reason is not visible in the web
  interface.
- GitHub runs the scheduled workflows with a delay, and the top of the hour
  is crowded — the cron of the workflow is at 06:17 UTC.

## The gaps to the real router

The package is built and checked for the router, but the guest is not the
router itself. What is known about the difference:

- The guest is the OpenWrt build `armsr/armv8-generic`
  (`aarch64_generic`), the router is `mediatek/filogic`
  (`aarch64_cortex-a53`) — the board cannot be emulated. The kernel is the
  same (6.12.112) and the OpenWrt release is the same.
- The package does not create `/etc/wg-portal` and carries no configuration:
  in the guest it is Ansible that writes it. On the router the file has to be
  written by hand (see the README).
- The dsn of `templates/openwrt/config.yaml.j2` is `/tmp/wg.db` — fine in
  the guest, wrong on the router, where `/tmp` is a tmpfs and the database
  would be gone after a reboot.
- The firewall zone for `wg0` exists as a step of Ansible in the role
  `tunnel` in the emulated guest; on the router the play `ansible/router.yml`
  makes it, together with the forwardings, the rule of the wan and the
  masquerade of the traffic of the tunnel.

## The caveats

- The router was touched once, on 2026-11-07, with the play of the opkg
  packaging of that time: the portal was installed and started. Nothing ran
  on it since — the apk packaging was checked against the emulated guest
  only.
- The key Ansible logs into the guest with is generated by the check and lives
  next to the flash of the router — a throwaway key for a throwaway guest, not
  a secret of anything.
- The dropbear of the guest generates its host keys on the first boot, and
  under the emulation that takes minutes. The image bakes the keys in, and a
  run on the host keeps them in the rootfs for the next one.
- Ansible transfers the files to the guest with scp: the dropbear of OpenWrt
  has no sftp server, so ansible falls back from sftp to scp on its own.
- The memory numbers come from an emulation, so the absolute `VmRSS`/`VmHWM`
  values are only meaningful as a comparison between the variants.
