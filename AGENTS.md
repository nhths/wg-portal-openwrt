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
- The packaging is a script (`scripts/build-ipk.sh`), not a play.
- The real router is never touched: no Ansible against it, no `opkg` on it.
  Everything runs in the emulated guest. The play `ansible/router.yml` is
  written for the user, who runs it — the agent only checks its syntax.
- Everything in the repository is in English.
- `ARCH` is the exact value of `opkg print-architecture` on the router
  (`aarch64_cortex-a53`); opkg refuses the package otherwise.
- The build artifacts are not tracked — see `.gitignore`.
- The secret key of the feed of the portal is never in the repository: only
  the public half is (`keys/wg-portal.pub`). The secret half is in the
  secrets of the CI and in `~/.config/wg-portal/secret.key` locally.

## The layout

```text
README.md                    what the thing is, how to install it, how to build it
AGENTS.md                    this file
Makefile                     the entry points
Dockerfile                   the image of the WireGuard check
Dockerfile.builder           the image that builds wg-portal from source
Dockerfile.pkg               the toolbox of the package: UPX, tar, Jinja2
Dockerfile.usign             the image with the usign of OpenWrt: it signs the
                             feed of the portal
.github/workflows/
  wg-portal-release.yml      the workflow of the release: the portal is checked
                             for updates every two weeks
keys/
  wg-portal.pub              the public key of the feed of the portal
ansible/
  site.yml                   the OpenWrt setup of the emulated router
  router.yml                 the feed of the portal on the real router
  inventory.ini              the emulated router is registered by the play
  ansible.cfg
  requirements.yml           the collections the play needs
  vars/main.yml              the defaults of the check
  roles/opwrt/tasks/         the setup: the feed, the portal, the service
  roles/tunnel/tasks/        the guest side of the check
  roles/package/tasks/       the checks of the installation of the package
templates/
  ipk/                       the files of the package: control, init script,
                             postinst, prerm
  openwrt/                   the network of the guest, the config of the portal
scripts/
  build-ipk.sh               download → UPX → build the .ipk
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
make dist           # download, pack with UPX, build the .ipk
make feed           # the index of the feed of the portal and the signature of it
make bench          # measure size, startup time and RAM in an emulated guest
make check-install  # install the .ipk in a guest OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
make build-src      # build wg-portal from source and compare the sizes
make lint           # shellcheck + ansible-lint + markdownlint
```

Docker with network access is required. The measurements and the checks need
`qemu-system-aarch64`; the WireGuard check needs root (it creates a tap
device) and `ethtool`.

The variables of the Makefile: `VER` (the version of the portal, `v2.3.1`),
`ARCH` (`aarch64_cortex-a53`), `REL` (the revision of the package, `1`),
`IMAGE`, `PKG_IMAGE`, `USIGN_IMAGE`, `TAG`, `DOCKER` (`docker` or `podman`),
`PUBLIC_KEY` (the public key of the feed) and `SECRET_KEY` (the secret half
of it).

## The build of the package

`make dist` builds the toolbox image (`Dockerfile.pkg`) and runs it:
`scripts/build-ipk.sh` downloads the release binary of the portal, packs it
with UPX, renders the files of the package from `templates/ipk/` and
assembles the `.ipk`.

The toolbox is Debian, because the busybox tar of Alpine does not know the
options the package needs (`--numeric-owner`, `--owner`, `--group`).

The structure of the package is verified: an outer archive of
`debian-binary`, `control.tar.gz`, `data.tar.gz`; `control` carries
`Architecture: aarch64_cortex-a53` and `Depends: kmod-wireguard`; `data`
carries `usr/bin/wg-portal` (755) and `etc/init.d/wg-portal` (755).

The package is 9.9 MB — that is what it takes of the 128 MB of the flash of
the router.

`Installed-Size` in `control` is counted in bytes (`du -sb`) — the same as in
the stock OpenWrt packages: opkg converts the value to KiB itself
(`pkg_size_kbs = (installed_size + 1023) / 1024`), so the Debian habit of
"kilobytes" does not apply here.

The container of the toolbox writes into `dist/` as the user of the host, so
the id of the host has to be kept inside it. Rootless podman maps the ids
of the users its own way and needs `--userns=keep-id` for that; the root of
the host is mapped to itself anyway, and the runner of the CI builds with
podman as root. The Makefile adds the flag when it is needed and only then.

The configuration of the portal is not in the package: the init script points
the binary at `/etc/wg-portal/config.yaml`, and the file has to be written on
the router. The keys of it are the sections of the configuration of the
portal — `core.admin_password`, `web.listening_address` and `database.dsn`
(the same names the environment variables `WG_PORTAL_CORE_ADMIN_PASSWORD` and
friends are built from). If the file should not be required at all, drop the
`procd_set_param env` line in `templates/ipk/init.d.j2`.

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

Both checks run the same machine: the stock OpenWrt 24.10.8 arm64 rootfs on
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
`kmod-udptunnel6`.

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
- `setup` installs the `.ipk` of the portal with opkg, loads the WireGuard
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
module by hand: opkg has to resolve the dependency itself, the way it does
on the router. The modules come from a feed — the index of the OpenWrt
repository with its signature, and the packages themselves — which the host
serves over HTTP to the guest:

```text
Installing wg-portal (2.3.1-1) to root...
Installing kmod-crypto-lib-chacha20 (6.6.144-r1) to root...
Downloading http://10.77.0.1:18080/kmod-crypto-lib-chacha20_6.6.144-r1_aarch64_generic.ipk
...
Installing kmod-wireguard (6.6.144-r1) to root...
Downloading http://10.77.0.1:18080/kmod-wireguard_6.6.144-r1_aarch64_generic.ipk
```

The index is signed by the build of the firmware, and the guest checks the
signature against the keys it has (`/etc/opkg/keys`) — the check of the
signature passes. The feeds of the firmware are dropped: the guest has no
internet, the feed of the check is the only one it can reach.

The feed of the check serves the whole chain of the dependencies of
`kmod-wireguard` (6.6.144-r1): `kmod-crypto-lib-curve25519`,
`kmod-crypto-lib-chacha20poly1305`, `kmod-crypto-lib-chacha20`,
`kmod-crypto-lib-poly1305`, `kmod-crypto-kpp`, `kmod-udptunnel4` and
`kmod-udptunnel6` — opkg downloads the ones it needs by itself.

### The quirks of opkg

- opkg knows no `file://` url: the feed has to be served over HTTP.
- The url of the feed is a **directory**: opkg appends `/Packages` and
  `/Packages.sig` to it.
- The architecture list comes from the `arch <name> <priority>` lines in
  `/etc/opkg.conf`, not from `/etc/opkg/arch.conf` (there is no such file in
  the OpenWrt image). As soon as `opkg.conf` contains a single such line, the
  default list `[all, noarch, <build arch>]` is *not* added — write the whole
  list.
- When opkg prints "Packages for X found, but incompatible with the
  architectures configured", the architecture is not the problem: opkg drops
  a candidate whose dependencies cannot be resolved
  (`pkg_hash_check_unresolved`) and the message about the architectures is
  misleading. The culprit is an unresolvable `Depends:`.
- The `openwrt/rootfs` container is useless for the install check: its opkg
  does not install local `.ipk` files at all — a genuine package from the
  OpenWrt repository (`464xlat_13_aarch64_generic.ipk`) fails the same way.
  The install check runs in a guest with a real OpenWrt root instead.

## The feed of the portal

A package installed by its url is in no feed, so opkg cannot update it: it
knows the version that is installed and nothing else. The feed is what makes
the update possible — it is the index of the packages, the signature of the
index and the packages themselves.

The index (`Packages`) is a list of stanzas, one per package:

```text
Package: wg-portal
Version: 2.3.1-1
Depends: kmod-wireguard
Section: net
Architecture: aarch64_cortex-a53
...
Filename: wg-portal_2.3.1-1_aarch64_cortex-a53.ipk
Size: 10403328
SHA256sum: ...
```

The control part of it is the control file of the package itself, so the
index cannot disagree with the package; `scripts/make-feed.sh` adds the three
fields that opkg needs and opkg does not take from the package.

The index is published twice: as it is (`Packages`) and compressed
(`Packages.gz`). The compressed one is not a nicety — LuCI reads the indexes
of the feeds with `gzip -cd` (`/usr/libexec/package-manager-call
list-available`), and that skips the files which are not compressed: with a
plain index only, the package is invisible to LuCI, and it shows up in the
list of the installed packages without a size and without a description. opkg
takes the compressed one itself, the same way it takes the indexes of the
feeds of the firmware. The signature is over the plain index: the signature is
checked against the index after it is unpacked.

### The signature

The signature is made with **usign**, not with GPG: OpenWrt 24.10 signs its
feeds with usign, and its opkg checks `Packages.sig` against the keys in
`/etc/opkg/keys` — a feed whose signature does not match is dropped. The
public key of the project is in the repository ([keys/wg-portal.pub](keys/wg-portal.pub)),
its fingerprint is `4aae624e9d888fea`. The secret half is not in the
repository: it is in the secrets of the CI (`OPKG_SECRET_KEY`) and, for the
local runs, in `~/.config/wg-portal/secret.key`.

```sh
make feed                       # the index and the signature of it
make feed SECRET_KEY=/somewhere/secret.key
```

The signing is done by the usign of OpenWrt — the packaged binary for
x86_64 (`Dockerfile.usign`), a build for musl, so it needs the loader and the
libraries of Alpine. The image of the check copies them into Debian together
with a wrapper (`/usr/local/bin/usign`).

The check of the signature is `usign -V -p <public key> -x <signature>
-m <index>`: it prints `OK` when the index is signed with the key.

### The feed of the check

The check does not use the key of the project: it generates a throwaway key
pair of its own (`usign -G -p ... -s ...`) and signs its feed with it. The
guest is given the public half of that key (`opkg-key add`), so the whole
chain is proved without a secret anywhere:

```text
Downloading http://10.77.0.1:18081/Packages
Downloading http://10.77.0.1:18081/Packages.sig
Signature check passed.
Installing wg-portal (2.3.1-1) to root...
```

The check serves the feed on the second port (18081), next to the port of
the feed of the firmware (18080): the guest has two feeds, the packages of
the portal come from one, the kernel modules from the other.

### The feed of the release

Every release publishes four more assets next to the package: `Packages`,
`Packages.gz`, `Packages.sig` and `wg-portal.pub`. The url of the feed is the
directory of the download of the last release:

```text
src wgp https://github.com/nhths/wg-portal-openwrt/releases/latest/download
```

The `Filename:` of the index carries the version, so the index is built
again for every release; the assets of the older releases stay where they
are, but `latest` points at the newest one.

### The play for the router

`ansible/router.yml` installs the feed on the real router: it fetches the
public key of the feed, checks its fingerprint, trusts it with `opkg-key
add`, points opkg at the feed and installs the portal from it. It is the
same chain the check of the emulated guest goes through, only on the device.

The play is self-contained — it needs nothing but Ansible and the access to
the router:

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

The play is a single file with no dependencies of its own, so it can be
piped from the mirror into Ansible — the path of the playbook is
`/dev/stdin`, `ansible-playbook -` does not read it from the pipe:

```sh
curl -sSL https://raw.githubusercontent.com/nhths/wg-portal-openwrt/master/ansible/router.yml \
  | ansible-playbook /dev/stdin
```

Only the modules of Ansible itself are used: the modules of the
community.openwrt collection would need a collection that is not in Ansible,
and the play has to work where nothing was installed for it. The router has
no Python, so the commands run through the `raw` module — it needs no
interpreter on the device.

The firmware of the router ships `/etc/opkg/customfeeds.conf` full of null
bytes, and opkg does not read such a file: the feed of the portal stays
invisible to it, and opkg answers "Cannot install package wg-portal". The
play drops the nulls before it adds the feed to the file. The same was
checked on the emulated guest — its `customfeeds.conf` is a normal file,
which is why the check of the feed passed there and the install of the
package did not happen on the router.

The session of dropbear needs the keepalive of the client as well: it drops
a session that receives nothing for 300 seconds (`-K 300`), and it counts the
packets it reads. The `ServerAliveInterval` of the ssh settings keeps the
session alive while the package is downloaded.

The configuration of the portal, the zone of the firewall and the service are
not in the play — they need the password of the portal.

The play was never run against the router — the user runs it. It was checked
against the emulated guest instead: the same device, the same OpenWrt, with
the feed of the check instead of the one of the release. Both ways were
checked — the file of the repository and the play piped from the mirror.

## The checks

`scripts/check.sh` boots the emulated router and has two modes:

- `install` — the package: the files opkg made of it, the service it enabled,
  the binary that answers HTTP, and that the package can be taken away again
  and installed once more.
- `wireguard` — the whole chain: the portal manages a real WireGuard server
  interface, a client connects with the configuration the portal hands out and
  pings through the tunnel, and the guest pings the client back.

```sh
./scripts/check.sh install     # on the host
make check-wireguard           # the same, but in the image of the check
```

The install check prints what opkg made of the package:

```text
=== install wg-portal_2.3.1-1_aarch64_cortex-a53.ipk
Installing wg-portal (2.3.1-1) to root...
Configuring wg-portal.
--- installed files:
-rwxr-xr-x 1 root root       333 /etc/init.d/wg-portal
-rwxr-xr-x 1 root root 10371636 /usr/bin/wg-portal
--- rc.d:
S99wg-portal -> ../init.d/wg-portal
--- status:
Package: wg-portal
Version: 2.3.1-1
Depends: kmod-wireguard
Status: install user installed
Architecture: aarch64_cortex-a53
```

After the install the packaged binary answers HTTP (`HTTP_OK`, RSS ~47.7 MB),
and `opkg remove` takes the package away again.

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
kernel modules) and Ansible with the collection — the check itself needs no
network.

The tun device is a device of the machine the container runs on: the `tun`
module has to be loaded there (`modprobe tun`). The runner of the group does
not have it yet, so the check job of the pipeline fails there with
`stat /dev/net/tun: no such file or directory` — that is why the job is
manual: the build job stays the blocking one.

The image is built with podman on the runner and with docker on a developer
machine, and podman does not expand the wildcards in the source of a `COPY`
(`COPY --from=usign /usr/lib/libubox.so. …` fails there with "no such file
or directory"). Everything the image of the check needs from the image of
the usign is copied by its exact path — the libraries of the usign are put
into `/opt/usign/lib` in the image of the usign itself.

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

## The workflow of the release

`.github/workflows/wg-portal-release.yml` is a GitHub Actions workflow. Every
two weeks (the 1st and the 15th of the month) it looks for a new release of
the portal (`h44z/wg-portal`). If there is one, it builds the package, checks
it in the emulated OpenWrt — the same check as `make check-wireguard` — and
publishes the `.ipk` as a release of the repository.

The state of the workflow is the release itself: if the version of the portal
is already released here, the run does nothing. The run can also be started
by hand (`workflow_dispatch`), with the version of the portal as the
argument.

The release carries the package twice — under its own name (the convention of
opkg) and under the name `wg-portal.ipk`, which does not change from release
to release, so the url of it stays the same:

```sh
opkg install https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.ipk
```

It carries the feed of the portal as well (see "The feed of the portal"):
`Packages`, `Packages.sig` and `wg-portal.pub`.

The workflow signs the index with the secret key from the secrets of the
repository (`OPKG_SECRET_KEY`) and checks the signature against the public
key of the repository afterwards — a secret that does not belong to that
key fails the release. It builds the index with `make feed-index` and signs
it with `make feed-sign`, not with `make feed`: the latter rebuilds the
package, and the released `.ipk` would not be the one the check image has
baked in.

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
  same (6.6.144) and the OpenWrt release is the same.
- The package does not create `/etc/wg-portal` and carries no configuration:
  in the guest it is Ansible that writes it. On the router the file has to be
  written by hand (see the README).
- The dsn of `templates/openwrt/config.yaml.j2` is `/tmp/wg.db` — fine in
  the guest, wrong on the router, where `/tmp` is a tmpfs and the database
  would be gone after a reboot.
- The firewall zone for `wg0` exists only as a step of Ansible in the role
  `tunnel`; on the router the zone has to be added by hand.

## The caveats

- The router was never touched: no `ansible`, no `opkg` on the live device.
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
