# AGENTS.md

The working notes of the project: how the package of [WG Portal](https://github.com/h44z/wg-portal) is
built, how the check works, and what is known about the router it is built for. The README is what the
thing is and how to install it.

## The rules of the project

- The files that go into the router or into the package are templates in `templates/`, rendered with
  Jinja2. The packaging is a script (`scripts/build-apk.sh`), not a play.
- The real router is only ever touched through the play `ansible/router.yml`. Everything else runs in
  the emulated guest.
- Everything in the repository is in English.
- `ARCH` is the exact value of the architecture of the router (`aarch64_cortex-a53`); apk refuses the
  package otherwise. The build artifacts are not tracked — see `.gitignore`.
- The secret half of the key of the feed is never in the repository: only the public half is
  (`keys/wg-portal.pem`). The secret half is in the secrets of the CI (`APK_SECRET_KEY`) and in
  `~/.config/wg-portal/secret.pem` locally.

## The build of the package

`make dist` builds the toolbox image (`Dockerfile.pkg`) and runs it: `scripts/build-apk.sh` downloads
the release binary of the portal, packs it with UPX, renders the files of the package from
`templates/apk/` and assembles the `.apk` with `apk mkpkg`. The toolbox is Debian: the busybox tar of
Alpine does not know the options the package needs (`--numeric-owner`, `--owner`, `--group`). The
apk-tools are the static build of Alpine, 3.0.9 — the format the OpenWrt 25.12 uses. The package
carries the metadata (`templates/apk/metadata.j2`), the binary in `usr/bin/wg-portal` (755), the init
script in `etc/init.d/` (755) and the list of the files in `lib/apk/packages/wg-portal.list`. Its
scripts are the ones of OpenWrt: `post-install` and `post-upgrade` enable the service, `pre-deinstall`
stops it and disables it. The service is enabled but not started: the package carries no
configuration, and the portal cannot run before it is written.

### The compression and the measurements

Only one mode is used: **`upx --best --lzma`**, and the packed binary is verified with `upx -t`.
Measured on v2.3.1 / linux-arm64 with UPX 4.2.4, in a full system emulation (qemu-system-aarch64,
Alpine 3.21 guest):

| Variant | Size | Startup | VmHWM | VmRSS |
| --- | --- | --- | --- | --- |
| `orig` | 41 353 378 B (39.4 MB) | 2.66 s | 30.7 MB | 30.7 MB |
| `--best` (NRV2E) | 14 119 956 B (13.5 MB) | 5.59 s | 52.7 MB | 47.7 MB |
| `--lzma` | 10 440 828 B (10.0 MB) | 8.08 s | 49.2 MB | 47.7 MB |
| **`--best --lzma`** | **10 371 636 B (9.9 MB)** | **7.98 s** | **49.2 MB** | **47.7 MB** |

All four variants answer HTTP on `127.0.0.1:8888`. The packing is the right trade for the router: the
flash is the scarce resource (128 MB) and the RAM is not (512 MB). The unpacked image ends up in
anonymous memory, so RSS grows from 30.7 MB to ~48 MB — the router has more than ten times the RAM
the packed binary needs.

## The quirks of apk

These are the things that cost time to find out. They are the reason the package is signed the way it
is, and why the play has the steps it has.

- The url of a feed is the url of its **index**: a url that ends with `.adb` is taken as it is, and
  the packages of the feed are taken from the same directory by their name. A url that does not end
  with `.adb` is the url of a v2 repository, and apk looks for `APKINDEX.tar.gz` in it.
- The name of a package of apk v3 is its name and its version: `kmod-wireguard-6.12.112-r1.apk` —
  with a dash, not an underscore.
- The architecture list comes from `/etc/apk/arch` — one architecture per line. The guest is
  `aarch64_generic` and the package is built for `aarch64_cortex-a53`, so the role writes both of
  them into the file.
- A package whose signature apk cannot check is not installed at all, and an index cannot be built
  from one either. The signature is inside the file, and the key it is made with is identified by
  its id — the first 16 bytes of the sha512 of the public point of the key.
- The signing happens while the package and the index are built (`apk mkpkg --sign-key`, `apk
  mkndx --sign-key`); an unsigned file cannot be signed afterwards.
- `apk add` does not upgrade a package that is installed already, and the module
  `community.openwrt.apk` with `state: present` does not upgrade either — it asks apk about the
  package first and does nothing when it is there. `state: latest` (community.openwrt 1.11.0 and
  later) installs the package and upgrades it when the feed has a newer version.
- The scripts of a package are run by apk with an environment of its own and nothing else:
  `APK_PACKAGE`, `APK_SCRIPT`, `PATH` and `PWD`. `IPKG_INSTROOT` — the variable of opkg, the one the
  scripts of OpenWrt use — is **not** set by apk. OpenWrt has its own hooks for its packages:
  `default_postinst` and `default_prerm` in `/lib/functions.sh`. They find the init scripts in
  `/lib/apk/packages/<name>.list`, and `default_postinst` enables **and starts** them. The package
  has hooks of its own — they enable the service and do not start it.
- apk records the uid and the gid of the files of a package. A package built by a user gets
  `nobody:nobody` instead of `root:root` — the toolbox therefore runs as root, and the artifacts in
  `dist/` are given back to the user of the host afterwards (`HOST_UID`, `HOST_GID`).

## The feed of the portal

A package installed by its url is in no feed, so apk cannot update it. The feed is what makes the
update possible. The index of a feed of apk v3 is `packages.adb` — the database of apk, in the binary
format of ADB. It is built by apk itself (`apk mkndx`), and it carries the metadata of every package
of the feed. `apk adbdump` prints it in a readable form; the last line of it is the signature of the
index, and `OK` means that it is made with a key the reader trusts. The signature is made with the
key of the project — an EC key of the curve P-256, the same kind the firmware of OpenWrt signs its own
feeds with. The public key is in the repository ([keys/wg-portal.pem](keys/wg-portal.pem)), the
secret half is not. The index is built from the package that is already signed: apk refuses to index
a package whose signature it cannot check, and the keys of the feed are the ones it checks it against
(`--keys-dir`). Every release publishes the index of the feed next to the package: `packages.adb` and
`wg-portal.pem`. The url of the feed is the url of the index —
`https://github.com/nhths/wg-portal-openwrt/releases/latest/download/packages.adb`. The name of the
package carries the version, so the asset of the release is `wg-portal-2.3.1.1.apk`.

## The checks

`scripts/check.sh` boots the emulated router and has two modes: `install` (the package: the files apk
made of it, the service it enabled, the binary that answers HTTP, and that the package can be taken
away again and installed once more) and `wireguard` (the whole chain: the portal manages a real
WireGuard server interface, a client connects with the configuration the portal hands out and pings
through the tunnel, and the guest pings the client back).

```sh
./scripts/check.sh install     # on the host
make check-wireguard           # the same, but in the image of the check
```

The guest is a stock OpenWrt 25.12.6 on a 128 MB flash with 512 MB of RAM. The feed of the check
serves the whole chain of the dependencies of `kmod-wireguard` — the crypto modules of curve25519,
chacha20, poly1305 and the udptunnel ones — and apk downloads the ones it needs by itself. The feed of
the portal is signed with the key of the project, and the guest is given that key. The chain the check
proves is the chain the router of the LAN goes through. The `K01wg-portal` link of `/etc/rc.d` is
made by apk itself, the `S99wg-portal` one by the init script of the package (`START=99`).
`make check-wireguard` runs the check in its own image: the emulated router with the portal inside
and the WireGuard client next to it, in one container. The container needs the tun device (`--device
/dev/net/tun`), the right to create the network interfaces in its namespace (`--cap-add NET_ADMIN`)
and the raw socket (`--cap-add NET_RAW`) — the ping of the client through the tunnel is an
`iputils-ping`, and without the raw socket it fails silently, on the standard error, where the log of
the check does not show it. The tun module has to be loaded on the machine the container runs on
(`modprobe tun`); the runner of the group does not have it yet, so the check job of the pipeline fails
there — that is why the job is manual and the build job stays the blocking one.

The API of the portal encodes every id: base64 with `=` → `-`, `/` → `_`, `+` → `.` (the interface id
in the peer paths is encoded the same way). The peer model wraps its configurable values (`Endpoint`,
`AllowedIPs`, `Dns`, …) into `{"Value": …, "Overridable": …}` — a plain string is rejected. Both are
handled in `scripts/portal-api.py`.

### The network of the check

```text
host (wg-test, 10.99.0.2) ──WireGuard──▶ router (wg0, 10.99.0.1)
   10.77.0.1 ──────────tap──────────▶ 10.77.0.2
```

The client cannot live in the same network namespace as the server: the address of the server
interface is a local address there, so the traffic never enters the tunnel. The client is therefore on
the host. The two are connected by a tap device, not by the user-mode network of QEMU: slirp rewrites
the UDP endpoints of the forwarded ports, and a WireGuard peer accepts the handshake response only
from the address it sent the request to. Over the user-mode network the guest receives the handshake,
answers it, and the answer is lost on the way back. The offloads of the tap have to be off (`ethtool
-K tap tso off gso off gro off tx off sg off`): the guest does not understand the checksum and
segmentation offload of the tap and drops the packets. The addresses of the tunnel (`10.99.0.1` and
`10.99.0.2` here) have to be free on the host: an address that is local there makes the answers of the
router arrive with a source address that is local as well, and the host drops them as a martian
source. The check says so and stops instead of failing silently.

## The play for the router

`ansible/router.yml` installs the feed on the real router: it fetches the public key of the feed,
checks it, trusts it with the module `community.openwrt.apk_feed` and installs the portal from it
with `community.openwrt.apk` (`state: latest`, so the portal is upgraded when the feed has a newer
version). The play needs the community.openwrt collection — the same one the check of the guest uses
(`ansible-galaxy collection install -r ansible/requirements.yml`). Its modules are ucode scripts, and
the router runs them: the router has no Python, and it needs none. Apart from that, the play needs
nothing but the access to the router: the public key it fetches itself, from the release; the address
of the router is a variable of the play (`router_address`), and the key of it is another one
(`router_ssh_key`, empty means the default key of the machine); and the inventory is not needed — the
router is registered by the play itself (`add_host`). The ports of the router are in
`ansible/vars/router.yml`.

The key of the feed is checked before it is trusted: the sha256 of it has to be the one of the
project (`c3f7c3d1651cd5d741245952d7fd533289532acff782235f1ec29184b71a9443`). The session of
dropbear needs the keepalive of the client as well: it drops a session that receives nothing for 300
seconds, and it counts the packets it reads. The configuration of the portal, the zone of the
firewall and the service are in the play as well: it writes the configuration of the portal when there
is none yet, puts the tunnel into the firewall — the zone by device, the forwardings in both
directions, the rule of the wan and the masquerade of the traffic of the tunnel — and starts the
service. The port of the tunnel is the standard port of WireGuard by default, another one with `-e
wireguard_port=...`. The play reads the port the portal really listens on from the configuration it
writes for the interface and stops when it is not the port of the variables: the rule of the firewall
would open a port nobody listens on.

## The firewall of the router

The router is a stock OpenWrt with a firewall (fw4) and the default policy `input REJECT`. The
interface of the portal belongs to no zone of it, and the traffic of a peer is not tracked by the
connection tracking: without a zone of its own, the echo request of the peer is rejected and the peer
gets an "unreachable" instead of the answer. The zone has to name the **device**, not a network:

```text
config zone
        option name 'wg'
        list device 'wg0'
        option input 'ACCEPT'
```

`list network 'wg0'` does not work: the interface of the portal is created by the portal itself and is
not in `/etc/config/network`, so a network of that name never matches any traffic — the zone stays
empty and the traffic of the peer keeps hitting the default policy. fw4 puts a rule of the firewall of
its own into the chain of the zone of its **source**, and that chain is entered by the traffic that
leaves through the zone — so such a rule masquerades the traffic that goes *into* the tunnel, and the
peers never answer the ping of the portal. The masquerade of the traffic on the way out is the `masq`
of the zone of the wan. The public address of the router is the address of the services of the
gateway, and the firewall of the router redirects the traffic of the wan zone to them. The traffic of
the tunnel is not redirected by that: it is delivered to the router itself, and the router answers it
with the certificate of its own web interface (uhttpd, the OpenWrt one).

fw4 builds the rules of the hairpin of the lan on its own. The play puts the zone of the tunnel into
the reflection of the redirects of the wan zone (`reflection_zone`), and it gives the zone of the
tunnel the network of the interface (`option subnet`) — fw4 needs the addresses of the peers for the
rules of the reflection. The masquerade of the way back is a rule of its own (`<name>_wg_snat`): the
rules of the reflection masquerade the traffic to the lan address of the router, but they land in
the chain of the zone of the tunnel — and the traffic of the peers leaves through the lan, so they
never apply to it. The rule of the play does it for the peers: the gateway answers to the router.

The rule is a section of the type `nat` and not a redirect with the target `SNAT`: LuCI nags about the
second form until it is migrated, and the migration is LuCI's business. The section is found by its
name and not created by it: a section that LuCI has migrated already carries that name, and the play
has to change it in place instead of adding a second one. The old form is taken away by the same
name, so that the rule of the `nat` is the only one.

### The proxy of the router

The router has a transparent proxy on it (podkop), and the traffic of the lan goes through it: the dns
of the router answers with the fake addresses of the proxy (198.18.0.0/15), and the proxy intercepts
the traffic to them with the mark `0x100000` and a tproxy to itself. The tunnel has to be in the list
of the interfaces of the proxy (`source_network_interfaces`), or the peers get the same fake addresses
and their traffic to them is not intercepted: it goes to the internet as it is, and nobody answers it.
The play adds the interface to the list and restarts the proxy — when the router has a proxy at all:
the play looks for the config and the service of it first, and leaves the router alone when there is
none.

### The routing of the router

The portal does not put the route of the peer into the main table. It gives the interface a firewall
mark, puts the route of the peer into a table with the number of that mark and adds a rule that sends
the marked traffic there:

```text
10.99.0.2 dev wg0 table 20003 scope link
0:      from all lookup local
32700:  from all fwmark 0x4e23 lookup 20003
32766:  from all lookup main
```

The mask of the rule is empty, so it matches every packet. The mark itself is never needed: the
WireGuard module marks the encapsulated packets, not the plaintext ones.

### The allowed IPs of the peers

The allowed IPs of a peer are the addresses the server routes **to** that peer, and the portal writes
them into the configuration of the interface. The module of WireGuard uses them twice: it picks the
peer of a packet by its destination address, and it checks the source address of every decrypted
packet against them — a packet whose source is not in them is dropped. Three things follow from that,
and all of them were seen on the router:

- The address of the peer itself is enough for a peer that reaches the internet: its traffic is
  masqueraded by the firewall of the wan and comes back to it by the route of the portal.
- A peer that reaches the **lan** needs the network of the lan in its allowed IPs — the source address
  of the packet of the lan client is not in the address of the peer otherwise, and the module drops
  the packet.
- Two peers with the **same** network in their allowed IPs shadow each other: the trie of the module
  keeps one peer per prefix, and the traffic of one of them is delivered to the other. `172.26.0.2/24`
  and `172.26.0.4/24` are the same prefix — `172.26.0.0/24` — and only one of the two peers ever
  receives the traffic of the network.

The address of the interface of the portal is the network itself (`172.26.0.0/24`): the network
address is not a valid source address, so the router cannot originate the traffic to the peers by
itself, and the ping of the portal to its peers fails for that reason.

## The workflow of the release

`.github/workflows/wg-portal-release.yml` is a GitHub Actions workflow. Every two weeks (the 1st and
the 15th of the month) and on every commit to master it looks for a new release of the portal
(`h44z/wg-portal`). If there is one, it builds the package, checks it in the emulated OpenWrt — the
same check as `make check-wireguard` — and publishes the `.apk` as a release of the repository. The
state of the workflow is the release itself: if the version of the portal is already released here,
the run does nothing. The tag of the release is the version of the package. The workflow signs the
package and the index with the secret key from the secrets of the repository (`APK_SECRET_KEY`) and
checks the signature of the index against the public key of the repository afterwards — a secret that
does not belong to that key fails the release. Two things to know about the scheduled runs: GitHub
delays them (a run can start an hour after its time), and it stops them altogether if the repository
has no activity for 60 days — a commit or a manual run brings them back. A workflow that is added in
the **first push** of a new repository is not indexed by GitHub (the repository is still being
provisioned): the file is there, but it is not in the list of the workflows. Any commit to master
fixes it — the workflow runs on every one of them.

## The gaps and the caveats

The package is built and checked for the router, but the guest is not the router itself. What is
known about the difference:

- The guest is the OpenWrt build `armsr/armv8-generic` (`aarch64_generic`), the router is
  `mediatek/filogic` (`aarch64_cortex-a53`) — the board cannot be emulated. The kernel (6.12.112)
  and the OpenWrt release are the same.
- The package does not create `/etc/wg-portal` and carries no configuration: in the guest it is
  Ansible that writes it. On the router the file has to be written by hand (see the README), and the
  dsn of `templates/openwrt/config.yaml.j2` — `/tmp/wg.db` — has to be changed too: `/tmp` is a
  tmpfs there, and the database would be gone after a reboot.
- The firewall zone for `wg0` exists as a step of Ansible in the role `tunnel` in the emulated
  guest; on the router the play `ansible/router.yml` makes it, together with the forwardings, the
  rule of the wan and the masquerade of the traffic of the tunnel.
- The router was touched once, on 2026-11-07, with the play of the opkg packaging of that time: the
  portal was installed and started. Nothing ran on it since — the apk packaging was checked against
  the emulated guest only.
- The key Ansible logs into the guest with is generated by the check and lives next to the flash of
  the router — a throwaway key for a throwaway guest, not a secret of anything. The dropbear of the
  guest generates its host keys on the first boot, which takes minutes under the emulation: the
  image bakes the keys in, and a run on the host keeps them for the next one. Ansible transfers the
  files with scp: the dropbear of OpenWrt has no sftp server.
- The memory numbers come from an emulation, so the absolute `VmRSS`/`VmHWM` values mean a comparison
  between the variants and nothing more.
