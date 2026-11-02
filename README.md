# wg-portal for OpenWrt

Pack the arm64 [WG Portal](https://github.com/h44z/wg-portal) release binary
with UPX, measure what the packing costs and buys, verify that the packed
binary really runs, and build an `.ipk` package for OpenWrt.

The original task brief is in
[`wg-portal-upx-ipk-bench.md`](wg-portal-upx-ipk-bench.md).

## Layout

```text
Makefile                     the entry points
scripts/
  build-ipk.sh               download → UPX → build the .ipk
  make-ipk.sh                assemble the .ipk from a binary
  bench.sh                   measure in an emulated arm64 guest
  check-install.sh           install the .ipk in the emulated router and run it
  check-wireguard.sh         end-to-end check of a real WireGuard tunnel
  portal-api.py              drive the portal API: interface, peer, config
  build-src.sh               build wg-portal from source and compare sizes
  vm/
    bench-one.sh             start one binary, measure startup time and RSS
    guest-bench.sh           /init of the measurement guest
    guest-install.sh         /init of the install-check guest
    guest-wireguard.sh       /init of the WireGuard guest
    build-flash.sh           build the 128 MB flash of the emulated router
    Dockerfile.builder       builder image: vite frontend + Go modules
```

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
make check-wireguard # check a real WireGuard tunnel through the portal
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
drop the `procd_set_param env` line in `scripts/make-ipk.sh`.

## The emulated router

Both checks run the same machine: the stock OpenWrt 24.10.8 arm64 rootfs on a
128 MB ext4 flash with 512 MB of RAM — the resources of the real router. The
flash is built with `mke2fs -d` (`scripts/vm/build-flash.sh`), attached as a
virtio disk, and the guest boots from it directly.

Two details of that kernel shape the guest scripts:

- it has **no devtmpfs**, so the device nodes (`/dev/null`, `/dev/urandom`, …)
  are created by hand;
- it has **no gzip decompressor for the initramfs** ("Initramfs unpacking
  failed: compression method gzip not configured"), so the rootfs cannot live
  in an initramfs — it lives on the flash.

The WireGuard modules come from the OpenWrt repository: `kmod-wireguard`,
the crypto modules it needs and `kmod-udptunnel4`/`kmod-udptunnel6`. Their
postinstall scripts load them, `modprobe` in the guest only fills the gaps.

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

1. boots the emulated router, installs the `.ipk` and the WireGuard modules
   with opkg;
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
=== pinging through the tunnel
PING 10.99.0.1 (10.99.0.1) from 10.99.0.2 wg-test: 56(84) bytes of data.
64 bytes from 10.99.0.1: icmp_seq=1 ttl=64 time=10.3 ms
...
=== waiting for the guest to ping through the tunnel
64 bytes from 10.99.0.2: seq=0 ttl=64 time=6.137 ms
3 packets transmitted, 3 packets received, 0% packet loss
TUNNEL_PING=OK
TUNNEL_TRAFFIC rx=980 tx=860
WG_STATUS=OK
```

## Caveats

- The router was never touched: no `ansible`, no `opkg` on the live device.
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
