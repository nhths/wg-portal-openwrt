# wg-portal for OpenWrt

Pack the arm64 [WG Portal](https://github.com/h44z/wg-portal) release binary
with UPX, measure what the packing costs and buys, verify that the packed
binary really runs, and build an `.ipk` package for OpenWrt.

The original task brief is in
[`wg-portal-upx-ipk-bench.md`](wg-portal-upx-ipk-bench.md).

## Layout

```text
Makefile                     the entry points
Dockerfile                   the image of the WireGuard check
Dockerfile.builder           the image that builds wg-portal from source
Dockerfile.pkg               the toolbox of the package: UPX, tar, Jinja2
.github/workflows/
  wg-portal-release.yml      the workflow of the release: the portal is checked
                             for updates every two weeks
ansible/
  site.yml                   the OpenWrt setup of the emulated router
  inventory.ini              the emulated router is registered by the play
  ansible.cfg
  requirements.yml           the collections the play needs
  vars/main.yml              the defaults of the check
  roles/opwrt/tasks/         the setup: the feed, the portal, the service
  roles/tunnel/tasks/        the guest side of the check
  roles/package/tasks/       the checks of the installation of the package
templates/
  ipk/                       the files of the package: init script, control
  openwrt/                   the network of the guest, the config of the portal
scripts/
  build-ipk.sh               download → UPX → build the .ipk
  build-src.sh               build wg-portal from source and compare sizes
  check.sh                   the checks: the package, the WireGuard tunnel
  guest.sh                   the emulated router: fetch, boot, flash
  bench.sh                   measure in an emulated arm64 guest
  bench-init.sh              the init of the measurement guest
  bench-one.sh               measure one binary: the startup time and the RSS
  portal-api.py              drive the portal API: interface, peer, config
```

Every file that is written into the router or into the package is a template
in `templates/` and is rendered with Jinja2 — one template syntax in the
project, and the files can be read on their own. The router is configured by
Ansible (it renders the templates on the controller), the package by the
script that builds it.

Build artifacts (downloaded binaries, the packed binary, the `.ipk`) are not
tracked — see `.gitignore`.

## Usage

Docker with network access is required. The measurements and the checks
additionally need `qemu-system-aarch64` (`pacman -S qemu-system-aarch64`).
The WireGuard check needs root (it creates a tap device) and `ethtool`.

```sh
make dist           # download, pack with UPX, build the .ipk
make bench          # measure size, startup time and RAM in an emulated guest
make check-install  # install the .ipk in a guest OpenWrt and start it
make image          # build the image of the WireGuard check
make check-wireguard # check a real WireGuard tunnel in that image
make build-src      # build wg-portal from source and compare the sizes
make lint           # shellcheck + markdownlint
```

`ARCH` is the exact value of `opkg print-architecture` on the router
(`aarch64_cortex-a53`); opkg refuses the package otherwise.

## Compression mode

Only one mode is used: **`upx --best --lzma`**.

Measured on v2.3.1 / linux-arm64 with UPX 4.2.4:

| Mode | Size | Ratio |
|---|---|---|
| original | 41 353 378 B (39.4 MB) | 100 % |
| `--best` (NRV2E) | 14 119 956 B (13.5 MB) | 34.1 % |
| `--lzma` | 10 440 828 B (10.0 MB) | 25.3 % |
| **`--best --lzma`** | **10 371 636 B (9.9 MB)** | **25.1 %** |

LZMA beats NRV2E by almost 3 MB, and `--best` on top of LZMA saves another
70 kB. The packed binary is verified with `upx -t`.

## Measurements

### arm64, full system emulation (qemu-system-aarch64, Alpine 3.21 guest)

| Variant | Size | Startup | VmHWM | VmRSS |
|---|---|---|---|---|
| `orig` | 41 353 378 B (39.4 MB) | 2.66 s | 30.7 MB | 30.7 MB |
| `--best` | 14 119 956 B (13.5 MB) | 5.59 s | 52.7 MB | 47.7 MB |
| `--lzma` | 10 440 828 B (10.0 MB) | 8.08 s | 49.2 MB | 47.7 MB |
| `--best --lzma` | 10 371 636 B (9.9 MB) | 7.98 s | 49.2 MB | 47.7 MB |

All four variants report `STATUS=OK`: the binary unpacks, starts and answers
HTTP on `127.0.0.1:8888`.

The absolute numbers are only meaningful within one round: the emulation is
CPU-bound and the first binary started in a guest pays the translation cache
warm-up (~0.4 s). Re-running the same guest on a loaded host shifts the
startup time of the packed variants by seconds. `make bench` measures the
unpacked original against the shipped mode only.

### amd64, native container (control run)

| Variant | Size | Startup | VmHWM | VmRSS |
|---|---|---|---|---|
| `orig` | 43 237 538 B (41.2 MB) | 0.32 s | 34.9 MB | 34.9 MB |
| `--best` | 15 583 964 B (14.9 MB) | 0.55 s | 56.0 MB | 54.2 MB |
| `--lzma` | 11 997 600 B (11.4 MB) | 1.02 s | 54.3 MB | 54.3 MB |
| `--best --lzma` | 11 914 616 B (11.4 MB) | 1.03 s | 52.5 MB | 52.2 MB |

### What it means

- **Size**: UPX saves 74 % (39.4 → 9.9 MB).
- **Startup**: unpacking costs 3–5 s on a slow emulation — less on real
  hardware, but the same order of magnitude. For a web UI that is started
  once a day it does not matter.
- **RAM**: the unpacked image ends up in anonymous memory, so RSS grows from
  30.7 MB to ~48 MB, i.e. **+55 %**. On a router with 128 MB of RAM that
  is the difference between "fits" and "does not fit". If memory matters more
  than flash, take the unpacked binary — every packed mode needs about the
  same amount of RAM.

For the router: `--best --lzma` is the best by size. `--best` costs 3.6 MB
more flash and starts ~2.4 s faster, but needs the same RAM — take it when
the flash is tight or the startup matters.

## Why not qemu-user

The first version of the benchmark ran the arm64 binary in an arm64 container
under `qemu-user` (binfmt). All four variants, including the unpacked
original, failed the same way:

```text
panic: failed to create local WireGuard controller:
       failed to create wgctrl client: socket: protocol not supported
```

The cause is neither UPX nor the kernel but the emulation itself: under
`qemu-user` the call `socket(AF_NETLINK, …, NETLINK_GENERIC)` returns
`EPROTONOSUPPORT`, and genetlink (and therefore wgctrl) cannot be created
without it. A 20-line Go reproducer shows it:

```text
native amd64:  netlink generic: fd=4 err=<nil>      netlink route: fd=5 err=<nil>
arm64/qemu:    netlink generic: fd=-1 err=protocol not supported
                                          netlink route: fd=4 err=<nil>
```

`NETLINK_ROUTE` works under qemu-user, `NETLINK_GENERIC` does not; natively
both work. Honest arm64 numbers therefore need **full system emulation** —
`qemu-system-aarch64` with an Alpine guest, where the guest kernel is a real
kernel. There every variant starts and answers HTTP.

## Building from source

The release binary is already stripped (`-ldflags "-w -s"`), and rebuilding
from source with the same flags gives a binary of the same size — the release
is reproduced:

| Build | Size |
|---|---|
| release binary v2.3.1 | 41 353 378 B (39.4 MB) |
| source build, upstream flags | 41 353 378 B (39.4 MB) |
| + trimmed assets | 36 831 394 B (35.1 MB) |

So upstream builds exactly `-ldflags "-w -s -extldflags '-static'" -tags netgo`,
and a rebuild on its own does not shrink anything. The real levers:

1. **Drop the dead assets** — the binary embeds FontAwesome fonts (3.9 MB) in
   every format: `eot`, `svg`, `ttf`, `woff`, `woff2`. Modern browsers need
   only `woff2`/`woff` — the rest (~2.2 MB) need not be embedded. Plus
   `assets/doc/*` (swagger json/yaml, 278 kB) and
   `assets/js/rapidoc-min.js` (843 kB) — the API documentation page.
   Together −4.5 MB (−11 %).
2. **The frontend itself** — vite builds `index.js` to 1.86 MB and `index.css`
   to 646 kB, plus ~1.5 MB of SVG flags for the country selector in i18n.
3. **Go dependencies** — the bulk of it (gin, gorm, ldap, oidc, sqlite). These
   can only be reduced by cutting features, i.e. by changing code, not by
   build flags.

Practical conclusion: if the goal is a smaller binary, UPX saves 74 % and a
plain rebuild saves nothing. A rebuild is worth it only when custom changes
are needed (version, default config, trimmed assets) — then the size can go
down to ~35 MB before UPX and ~9 MB after.

## Package

Built: `wg-portal_2.3.1-1_aarch64_cortex-a53.ipk` (9.9 MB) — the
`--best --lzma` variant, for the router architecture
(`mediatek/filogic` → `aarch64_cortex-a53`).

The target is the router of the LAN: RouteRich AX3000 v1 (ARMv8,
`mediatek/filogic`, kernel 6.6.144) on RouteRich 24.10.8. It runs the same
OpenWrt release and the same kernel the guest of the check emulates, and
its `opkg print-architecture` is `aarch64_cortex-a53` — the architecture
of the package.

The structure is verified: an outer archive of `debian-binary`,
`control.tar.gz`, `data.tar.gz`; `control` carries
`Architecture: aarch64_cortex-a53`; `data` carries `usr/bin/wg-portal` (755)
and `etc/init.d/wg-portal` (755).

The installation is verified in a guest OpenWrt 24.10.8 for arm64
(`make check-install`):

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

The package carries no config: the path `/etc/wg-portal/config.yaml` in the
init script is there for future use. If the file should not be required,
drop the `procd_set_param env` line in `templates/ipk/init.d.j2`.

### The installation on the router

opkg installs a package from an url by itself, so the package is installed
on the router with one command:

```sh
opkg install https://github.com/nhths/wg-portal-openwrt/releases/latest/download/wg-portal.ipk
```

The name of the asset is the same in every release, so the command does not
change; the version is in the release and in the package itself. A newer
release is installed with the same command — opkg sees the version in the
package and upgrades.

The dependency of the package, the WireGuard kernel module, opkg pulls in
itself — from the feeds of the firmware, so the router needs the internet.
If the feeds are not reachable, the module has to be installed first, or the
package with `opkg install --force-depends`.

The package carries no configuration, so the portal is written by hand
before the first start:

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
/etc/init.d/wg-portal enable
/etc/init.d/wg-portal start
```

The `dsn` is on the flash and not in `/tmp`: `/tmp` is a tmpfs, so the
database of the portal is gone after a reboot.

### The packaging

`make dist` builds the toolbox image (`Dockerfile.pkg`) and runs it: the
script `scripts/build-ipk.sh` downloads the release binary, packs it with
UPX, renders the files of the package from `templates/ipk/` and assembles the
`.ipk`.

```sh
docker build -f Dockerfile.pkg -t wg-portal-pkg:local .
docker run --rm -v "$PWD/dist:/w" wg-portal-pkg:local
```

The toolbox is Debian, because the busybox tar of Alpine does not know the
options the package needs (`--numeric-owner`, `--owner`, `--group`).

## The workflow of the release

`.github/workflows/wg-portal-release.yml` is a GitHub Actions workflow. Every
two weeks (the 1st and the 15th of the month) it looks for a new release of
the portal (`h44z/wg-portal`). If there is one, it builds the package, checks
it in the emulated OpenWrt — the same check as `make check-wireguard`, the
package is installed with opkg and a real WireGuard tunnel is made through it
— and publishes the `.ipk` as a release of the repository.

The state of the workflow is the release itself: if the version of the portal
is already released here, the run does nothing. The run can also be started by
hand (`workflow_dispatch`), with the version of the portal as the argument.

The workflow runs the code of the repository it is in, so the GitHub copy of
the project is the one the Actions run in; the GitLab repository is the source
of truth.

Two things to know about the scheduled runs: GitHub delays them (a run can
start an hour after its time), and it stops them altogether if the repository
has no activity for 60 days — a commit or a manual run brings them back.

## The emulated router

Both checks run the same machine: the stock OpenWrt 24.10.8 arm64 rootfs on a
128 MB ext4 flash with 512 MB of RAM — the resources of the real router. The
flash is built with `mke2fs -d` (`scripts/guest.sh flash`), attached as a
virtio disk, and the guest boots from it directly with the kernel of the
release, the way the OpenWrt guide for QEMU describes it.

The guest is a real OpenWrt: it boots with its own `init` (procd), so the
services of the packages work as they do on the router. Two things are baked
into the flash, because Ansible needs them to get in at all:

- the address of the guest (`/etc/config/network`) — the tap between the host
  and the guest has no DHCP server; the file is rendered from
  `templates/openwrt/network.j2` into the rootfs before the flash is built;
- the key Ansible logs in with (`/etc/dropbear/authorized_keys`).

Everything else is the setup of the guest, and that is what Ansible does (see
below).

The WireGuard modules come from the OpenWrt repository: `kmod-wireguard`,
the crypto modules it needs and `kmod-udptunnel4`/`kmod-udptunnel6`.

## The setup of the guest, by Ansible

`ansible/` converges the OpenWrt guest over SSH with the same collection the
LAN router is converged with (`community.openwrt`): its modules are ucode
scripts, so the guest needs no Python. The play is run by the check in three
steps, because the network of the guest has to be in the flash before it
boots, the guest has to be up before the portal can be started and the client
has to be up before the tunnel can be checked:

```sh
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags net \
  -e @/tmp/wgp-vm/vars.json
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags setup \
  -e @/tmp/wgp-vm/vars.json
ansible-playbook -i ansible/inventory.ini ansible/site.yml --tags verify \
  -e @/tmp/wgp-vm/vars.json
```

The `net` tag writes `/etc/config/network` into the rootfs of the guest, on
the controller — the router is not up yet. The `setup` tag installs the `.ipk`
of the portal with opkg, loads the WireGuard modules, writes
`/etc/wg-portal/config.yaml` and starts the service. The `verify` tag waits
for the traffic in the tunnel and pings the client back from the guest.

### The dependency of the portal

The portal depends on `kmod-wireguard`, and the check does not install that
module by hand: opkg has to resolve the dependency itself, the way it does on
the router. The modules come from a feed — the index of the OpenWrt
repository with its signature, and the packages themselves — which the host
serves over HTTP to the guest (opkg knows no `file://` url):

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

The files the play writes are rendered from `templates/openwrt/` — the
configuration of the portal is `templates/openwrt/config.yaml.j2`, and the
`community.openwrt.template` module renders it on the controller and copies
the result to the guest.

The collection is installed with
`ansible-galaxy collection install -r ansible/requirements.yml`.

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

## The image of the check

`make check-wireguard` runs the check in its own image: the emulated router
with the portal inside and the WireGuard client next to it, in one container.

```sh
docker build -t wg-portal-check .
docker run --rm --device /dev/net/tun --cap-add NET_ADMIN wg-portal-check
```

The container needs the tun device (`--device /dev/net/tun`) and the right to
create the network interfaces in its namespace (`--cap-add NET_ADMIN`): the
tap between the host and the guest and the WireGuard interface of the client
are both created there. The image brings QEMU, the WireGuard tools, the guest
(the rootfs, the kernel and the kernel modules) and Ansible with the
collection — the check itself needs no network.

The tun device is a device of the machine the container runs on: the `tun`
module has to be loaded there (`modprobe tun`). The runner of the group does
not have it yet, so the check job of the pipeline fails there with
`stat /dev/net/tun: no such file or directory` — that is why the job is
manual: the build job stays the blocking one.

## WireGuard check

`make check-wireguard` checks the whole chain, not only the web UI: the
packaged portal runs in the emulated router, creates a real WireGuard server
interface, hands out a peer configuration through the API, and a client on
the host connects with that configuration and pings through the tunnel.

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

What the check does:

1. boots the emulated router and lets Ansible set it up (the packages, the
   modules, the configuration, the service);
2. creates the interface `wg0` (server mode, port 51820) and a peer through
   the API — the same API the web UI talks to (`scripts/portal-api.py`);
3. takes the configuration the portal returns and brings the client up with
   it;
4. pings 10.99.0.1 through the tunnel, and the guest pings the client back;
   the counters of the interface inside the guest show the traffic.

The result is `WG_STATUS=OK`: the host pings the server through the tunnel,
the guest pings the client back, and the counters of the interface in the
guest grow accordingly.

```text
=== verifying the tunnel from the guest
TUNNEL_PING=OK
TUNNEL_TRAFFIC 564 476
=== pinging through the tunnel
PING 10.99.0.1 (10.99.0.1) from 10.99.0.2 wg-test: 56(84) bytes of data.
64 bytes from 10.99.0.1: icmp_seq=1 ttl=64 time=2.26 ms
64 bytes from 10.99.0.1: icmp_seq=2 ttl=64 time=1.59 ms
64 bytes from 10.99.0.1: icmp_seq=3 ttl=64 time=1.60 ms

3 packets transmitted, 3 received, 0% packet loss, time 2002ms
WG_STATUS=OK
```

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

The mask of the rule is empty, so it matches every packet, and the lookups
of the guest find the route of the peer. The mark itself is never needed:
the WireGuard module marks the encapsulated packets, not the plaintext ones.

## Caveats

- The router was never touched: no `ansible`, no `opkg` on the live device.
- The configuration of the portal is `/etc/wg-portal/config.yaml` — the init
  script of the package points the binary at it. The keys are the sections of
  the configuration of the portal: `core.admin_password`,
  `web.listening_address` and `database.dsn` (the same names the environment
  variables `WG_PORTAL_CORE_ADMIN_PASSWORD` and friends are built from).
- The key Ansible logs into the guest with is generated by the check and lives
  next to the flash of the router — a throwaway key for a throwaway guest, not
  a secret of anything.
- The dropbear of the guest generates its host keys on the first boot, and
  under the emulation that takes minutes. The image bakes the keys in, and a
  run on the host keeps them in the rootfs for the next one.
- Ansible transfers the files to the guest with scp: the dropbear of OpenWrt
  has no sftp server, so ansible falls back from sftp to scp on its own.
- `Installed-Size` in `control` is counted in bytes (`du -sb`) — the same as in
  the stock OpenWrt packages: opkg converts the value to KiB itself
  (`pkg_size_kbs = (installed_size + 1023) / 1024`), so the Debian habit of
  "kilobytes" does not apply here.
- The memory numbers come from an emulation, so the absolute `VmRSS`/`VmHWM`
  values are only meaningful as a comparison between the variants.
- The `openwrt/rootfs` container is useless for the install check: its opkg
  does not install local `.ipk` files at all — a genuine package from the
  OpenWrt repository (`464xlat_13_aarch64_generic.ipk`) fails the same way.
  The install check runs in a guest with a real OpenWrt root instead.
- When opkg prints "Packages for X found, but incompatible with the
  architectures configured", the architecture is not the problem: opkg drops
  a candidate whose dependencies cannot be resolved
  (`pkg_hash_check_unresolved`) and the message about the architectures is
  misleading. In our case the culprit is `Depends: kmod-wireguard`, which is
  missing from the test system. On the router it is present, so the
  dependency is correct.
- opkg takes its architecture list from the `arch <name> <priority>` lines in
  `/etc/opkg.conf`, not from `/etc/opkg/arch.conf` (there is no such file in
  the OpenWrt image). And as soon as `opkg.conf` contains a single such line,
  the default list `[all, noarch, <build arch>]` is *not* added — write the
  whole list.
- The API of the portal encodes every id: base64 with `=` → `-`, `/` → `_`,
  `+` → `.` (the interface id in the peer paths is encoded the same way).
  The peer model wraps its configurable values (`Endpoint`, `AllowedIPs`,
  `Dns`, …) into `{"Value": …, "Overridable": …}` — a plain string is
  rejected. Both are handled in `scripts/portal-api.py`.
- The peer configuration the portal hands out carries the allowed IPs of the
  *peer* (`10.99.0.0/24` here). The client routes that network into the
  tunnel, the server uses it to check the source address of the packets.
- The addresses of the tunnel (`10.99.0.1` and `10.99.0.2` here) have to be
  free on the host. An address that is local there makes the answers of the
  router arrive with a source address that is local as well, and the host
  drops them as a martian source — the tunnel carries the traffic and nothing
  answers. The check says so and stops instead of failing silently; the
  image of the check has its own network namespace and is not affected.
