# MihoWRT

MihoWRT is a LuCI package and runtime policy layer for running
Mihomo on OpenWrt APK-based systems.

The package does not try to replace Mihomo routing logic. Mihomo still
uses its own `config.yaml`, proxy groups, rule providers, DNS settings,
and TPROXY listener. MihoWRT wraps that with OpenWrt-specific glue:

- LuCI pages for service control, Mihomo config editing, traffic policy,
  and diagnostics.
- Direct-first and proxy-first nftables policy modes that send selected
  IPv4 traffic to Mihomo through TPROXY.
- Policy routing for marked packets.
- Optional DNS/53 redirect from selected client interfaces.
- `dnsmasq` upstream redirection to Mihomo DNS while the policy layer is
  active.
- Runtime cache placement in tmpfs to reduce flash writes.
- Snapshot and recovery logic for safe reloads and crash cleanup.
- Installer logic for package update, Mihomo core update, rollback, and
  user config preservation.

The current design is intentionally IPv4-focused. The default bundled
Mihomo config has `ipv6: false` and `dns.ipv6: false`; nft policy rules
only match IPv4. This keeps router-side rules simple and predictable on
networks where IPv6 is not used.

## Requirements

Runtime package dependencies:

```text
luci-base
jq
nftables
kmod-nft-tproxy
wget-any (wget provider)
```

The runtime also expects normal OpenWrt base tools and services:

```text
uci
ip
dnsmasq
procd
logread
```

`pgrep` is optional. MihoWRT can use it as a fallback when pid files are
missing.

## Quick Install

Run on the router:

```sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

or:

```sh
curl -fsSL https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

Interactive menu:

```text
1. Install/update package + kernel
2. Install/update kernel only
3. Remove package + kernel
4. Stop
```

Non-interactive mode:

```sh
MIHOWRT_ACTION=package wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
MIHOWRT_ACTION=kernel  wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
MIHOWRT_ACTION=remove  wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
MIHOWRT_ACTION=stop    wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

Accepted aliases:

- `package`, `pkg`, `install`, `update`, `1`
- `kernel`, `core`, `2`
- `remove`, `delete`, `uninstall`, `3`
- `stop`, `cancel`, `4`

In installer text, "kernel" means the Mihomo core binary at
`/opt/clash/bin/clash`, not the Linux/OpenWrt kernel.

The installer downloads the latest `luci-app-mihowrt-*.apk` from this
project release and the latest Mihomo binary from the MetaCubeX/mihomo
release. The APK does not bundle the Mihomo core binary.

## What Is Installed

Main runtime files:

```text
/etc/config/mihowrt
/etc/init.d/mihowrt
/etc/init.d/mihowrt-recover
/usr/bin/mihowrt
/usr/lib/mihowrt/
/usr/share/luci/menu.d/luci-app-mihowrt.json
/usr/share/rpcd/acl.d/luci-app-mihowrt.json
/www/luci-static/resources/view/mihowrt/
/www/luci-static/resources/mihowrt/
/opt/clash/config.yaml
/opt/clash/lst/always_proxy_dst.txt
/opt/clash/lst/always_proxy_src.txt
/opt/clash/lst/direct_dst.txt
```

Mihomo dashboard UI is not stored in this repository. The default
Mihomo config uses `external-ui-url`, so Mihomo downloads UI files into
the configured `external-ui` path.

Mihomo core:

```text
/opt/clash/bin/clash
```

Runtime state:

```text
/tmp/mihowrt/
/var/run/mihowrt/
/tmp/clash/ruleset
/tmp/clash/proxy_providers
/tmp/clash/cache.db
```

Persistent recovery state:

```text
/etc/mihowrt/dns.backup
/etc/apk/protected_paths.d/mihowrt.list
```

`/opt/clash/config.yaml` and policy list files are package
conffiles. APK protected paths also mark them as user-owned state.
Updates should preserve user edits and explicit user deletion of default
list files.

The package also installs `/lib/upgrade/keep.d/mihowrt`, so OpenWrt
`sysupgrade` with config preservation keeps MihoWRT's UCI config,
Mihomo config, policy list directory, and persistent DNS recovery state.

## Source Of Truth

MihoWRT has four user-controlled inputs.

1. `/opt/clash/config.yaml`

   This is the real Mihomo YAML config. MihoWRT reads only selected
   scalar fields from it for OpenWrt runtime integration:

   - `dns.listen`
   - `dns.enhanced-mode`
   - `dns.fake-ip-range`
   - `tproxy-port`
   - `routing-mark`
   - `external-controller`
   - `external-controller-tls`
   - `secret`
   - `external-ui`
   - `external-ui-name`

   Full Mihomo syntax is still checked by Mihomo itself with:

   ```sh
   /opt/clash/bin/clash -d /opt/clash -f /opt/clash/config.yaml -t
   ```

2. `/etc/config/mihowrt`

   UCI settings control the OpenWrt-side policy layer:

   ```text
   option enabled '1'
   list source_network_interfaces 'br-lan'
   option dns_hijack '1'
   option disable_quic '1'
   option route_table_id ''
   option route_rule_priority ''
   option subscription_url ''
   ```

   Empty `route_table_id` and `route_rule_priority` mean auto-select.
   Empty `subscription_url` means no subscription is configured.

3. `/opt/clash/lst/always_proxy_dst.txt` and
   `/opt/clash/lst/always_proxy_src.txt`

   These lists define traffic that must be sent to Mihomo before Mihomo
   rule matching. They can contain manual entries and remote http(s)
   list URLs. See "Traffic Policy Lists" below.

4. `/opt/clash/lst/direct_dst.txt`

   In proxy-first mode, this list defines destination IPs or destination
   IP + port rules that bypass Mihomo. It can contain manual entries and
   remote http(s) list URLs.

Runtime snapshots in `/var/run/mihowrt` are not a source of truth. They
describe what is currently applied so reload, diagnostics, and cleanup
can distinguish active state from desired on-disk config.

## LuCI Pages

MihoWRT adds three pages under Services -> MihoWRT.

### Mihomo Config

This page edits raw `/opt/clash/config.yaml` in an Ace editor.

Buttons:

- `Start MihoWRT`: starts the service.
- `Stop MihoWRT`: stops the service and cleanup runs from service exit.
- `Enable Autostart`: enables `/etc/init.d/mihowrt`.
- `Disable Autostart`: disables `/etc/init.d/mihowrt`.
- `Open Mihomo Dashboard`: opens the configured Mihomo external UI.
- `Save Subscription URL`: stores the subscription URL in UCI without
  changing the active Mihomo config.
- `Fetch Subscription`: downloads the subscription with `wget`, using
  `mihowrt/<package-version>` as User-Agent, and loads the result into
  the editor. The config is not saved until `Validate & Apply Config`.
  Downloads are limited to 1 MiB by default to keep LuCI responsive on
  routers.
- `Validate & Apply Config`: validates YAML through Mihomo, validates
  required MihoWRT runtime fields, writes the config only after
  validation succeeds, and restarts MihoWRT if it was running.

Config apply uses a temporary file under `/tmp`. It does not overwrite
the live config until both checks pass:

1. Mihomo accepts the YAML with `-t`.
2. MihoWRT can read valid DNS listen, TPROXY port, routing mark, and
   fake-ip settings.

### Traffic Policy

This page edits `/etc/config/mihowrt` and policy list files.

Standard LuCI save buttons keep their normal meaning:

- Save writes values to disk.
- Save & Apply writes values and applies UCI changes.

If only policy list files changed and the service is running, the page
reloads MihoWRT policy after saving. If the service is stopped, changes
stay on disk and apply on next start.

### Diagnostics

This page reads:

- `/usr/bin/mihowrt status-json`
- `/usr/bin/mihowrt logs-json 200`

It shows service state, active runtime snapshot, desired config, config
parse errors, DNS backup state, route state, and MihoWRT-related system
logs. `Refresh Diagnostics` reloads only this page data.

## Service Lifecycle

OpenWrt starts MihoWRT through `/etc/init.d/mihowrt`, which is a procd
service wrapper around:

```sh
/usr/bin/mihowrt run-service
```

Start sequence:

1. `/etc/init.d/mihowrt start` refuses to start if the installer
   skip-start marker exists.
2. It runs `/usr/bin/mihowrt recover` to clean stale state from an
   unclean shutdown.
3. It validates the Mihomo config with `clash -d /opt/clash -f ... -t`.
4. It validates MihoWRT runtime config.
5. It runs `/usr/bin/mihowrt cleanup` to remove stale nft, route, DNS,
   and snapshot state before a clean start.
6. procd starts `/usr/bin/mihowrt run-service`.
7. `run-service` loads config, validates again, prepares tmpfs runtime
   layout, and starts Mihomo as:

   ```sh
   /opt/clash/bin/clash -d /opt/clash -f /opt/clash/config.yaml
   ```

8. MihoWRT waits until Mihomo DNS and TPROXY listeners are ready.
9. If `option enabled '1'`, it applies policy routing, nftables rules,
   DNS state, and saves a runtime snapshot.
10. When the Mihomo process exits or the service is stopped, cleanup
    restores DNS, removes nftables table, removes policy route state,
    and clears runtime snapshots.

The `-d /opt/clash` argument makes Mihomo resolve relative paths from
`/opt/clash`. The `-f` argument pins the exact config file path. Without
`-f`, Mihomo would use its default config discovery and MihoWRT could
start a different config than the one LuCI validates and edits.

## Runtime Layout And Flash Writes

MihoWRT moves write-heavy Mihomo runtime paths to tmpfs:

```text
/opt/clash/ruleset          -> /tmp/clash/ruleset
/opt/clash/proxy_providers  -> /tmp/clash/proxy_providers
/opt/clash/cache.db         -> /tmp/clash/cache.db
```

If a real directory or file already exists at the `/opt/clash` path,
MihoWRT copies it to `/tmp` before replacing the original path with a
symlink. This keeps existing data for the current boot but avoids future
cache writes to flash.

One persistent file is intentionally written when DNS runtime state is
first applied:

```text
/etc/mihowrt/dns.backup
```

That file exists so boot recovery can restore `dnsmasq` even after power
loss, where `/var/run` and `/tmp` are gone. Routine runtime snapshots are
kept in `/var/run/mihowrt`, not flash.

## Traffic Policy Lists

Policy list files support comments, blank lines, manual entries, and
remote `http://` or `https://` list URLs. Remote lists are fetched when
policy is applied or the service starts. Their contents are merged with
manual entries in `/tmp`; the persistent list files are not rewritten.

Valid entries:

```text
ip
ip/mask
ip:port
ip/mask:port
:port
```

Port formats:

```text
443
15-2000
15,443,8443
```

Rules:

- Ports must be `1..65535`.
- Ranges must have `start <= end`.
- Comma lists contain concrete ports only.
- Mixed range/list syntax like `15-20,443` is intentionally invalid.
- IPv6 entries are not supported.
- Invalid entries are skipped and logged as warnings.
- Remote URLs inside a remote list are ignored, so lists do not recurse.
- A remote list fetch failure fails policy apply/reload. Existing runtime
  state is kept through rollback when a snapshot exists.
- Each remote list is limited to 256 KiB by default. Each effective list
  is limited to 1 MiB by default.
- Remote list fetches use a 15 second per-URL timeout, a 60 second total
  apply budget, and a 32 URL safety cap by default.

Examples:

```text
# Any TCP/UDP traffic to this destination IP
1.1.1.1

# Any TCP/UDP traffic to this destination subnet
8.8.8.0/24

# Only destination port 443 for this IP
1.1.1.1:443

# Destination port range for this subnet
100.100.100.100/20:15-2000

# Concrete destination ports for this IP
1.1.1.1:15,443,8443

# Any IPv4 destination/client on these ports
:443
:80,443

# Merge remote entries with manual entries
https://example.com/mihowrt-list.txt
```

Destination list semantics:

- `always_proxy_dst.txt` matches destination address.
- Port-qualified entries match destination port.
- `:port` matches any IPv4 destination on that destination port.
- Destination policy applies to client traffic in prerouting and to
  router-originated traffic in output.

Source list semantics:

- `always_proxy_src.txt` matches source/client address.
- Port-qualified entries still filter by destination port.
- `:port` means any IPv4 client traffic from selected source interfaces
  to that destination port.
- Source policy applies only to prerouting traffic from configured
  source interfaces. It does not apply to router-originated output
  traffic because router-originated packets have no client source
  interface in the same sense.

Performance model:

- IP-only entries are loaded into nftables interval sets:
  `proxy_dst`, `proxy_src`, and `direct_dst`.
- Port-qualified entries are emitted as direct nftables rules, because
  the existing `ipv4_addr` interval sets cannot also carry port
  metadata without changing set type and old behavior.
- This keeps the common IP/CIDR-only path fast while allowing port
  filters where needed.

## nftables Runtime

MihoWRT owns one table:

```text
table inet mihowrt
```

Main sets:

```text
proxy_dst      ipv4_addr interval set for destination policies
proxy_src      ipv4_addr interval set for source policies
localv4        reserved/local IPv4 ranges
source_ifaces  configured ingress interfaces
```

Main chains:

```text
dns_hijack          nat prerouting, priority dstnat
mangle_prerouting   filter prerouting, priority -150
prerouting_policy   regular chain jumped from mangle_prerouting
mangle_output       route output, priority -150
proxy_redirect      filter prerouting, priority -100
```

Important rule order:

1. DNS/53 redirect happens in `dns_hijack` before normal routing
   decisions.
2. Client traffic enters policy only if input interface is in
   `source_ifaces`.
3. `localv4` destinations return early. Private, loopback, multicast,
   reserved, and other local IPv4 ranges are not proxied, even with
   `:port` entries.
4. Already marked packets return to avoid re-marking loops.
5. If QUIC blocking is enabled, UDP/443 selected by policy is rejected
   before marking.
6. Selected TCP/UDP traffic gets mark `0x00001000`.
7. `proxy_redirect` TPROXYs marked TCP/UDP packets to
   `127.0.0.1:<tproxy-port>`.
8. Router-originated output traffic has a separate route hook. It uses
   destination policies and fake-ip catch, but not source/client policy.

If Mihomo DNS enhanced mode is `fake-ip`, MihoWRT also marks traffic to
`dns.fake-ip-range`. That lets Mihomo receive fake-ip connections even
when the destination is not present in the manual policy lists.

## Policy Routing

Mihomo TPROXY needs marked packets routed to local loopback. MihoWRT
sets:

```sh
ip rule add fwmark 0x00001000/0x00001000 table <table> priority <priority>
ip route replace local 0.0.0.0/0 dev lo table <table>
```

Defaults:

```text
table id range: 200..252
priority range: 10000..10999
```

If `route_table_id` or `route_rule_priority` are empty, MihoWRT
auto-selects free values. The effective values are saved to:

```text
/var/run/mihowrt/route.state
```

On reload, MihoWRT reuses saved values if they are still safe. If a
saved auto table or priority becomes occupied by foreign state, MihoWRT
moves to a free value and tears down the old managed route/rule after a
successful apply.

MihoWRT refuses invalid explicit values and refuses explicit table or
priority conflicts instead of overwriting unrelated router state.

The Mihomo `routing-mark` from `config.yaml` must not equal MihoWRT's
intercept mark `0x00001000`; otherwise Mihomo-originated packets and
MihoWRT-intercepted packets would be indistinguishable.

## DNS Behavior

There are two separate DNS mechanisms.

### dnsmasq upstream redirection

When the policy layer is active, MihoWRT configures `dnsmasq` to send
router DNS resolution through Mihomo DNS:

```text
dhcp.@dnsmasq[0].server    = <mihomo dns listen as host#port>
dhcp.@dnsmasq[0].cachesize = 0
dhcp.@dnsmasq[0].noresolv  = 1
dhcp.@dnsmasq[0].resolvfile cleared
```

Before changing `dnsmasq`, MihoWRT stores original state in runtime and
persistent backup files. Cleanup restores the original state. If backup
is missing but current DNS state clearly still points to Mihomo, fallback
restore returns `dnsmasq` to OpenWrt defaults.

### Client DNS/53 redirect

If `option dns_hijack '1'`, MihoWRT also redirects client TCP/UDP port
53 traffic from `source_network_interfaces` to Mihomo DNS. This catches
clients that ignore router DHCP DNS settings.

If `dns_hijack` is disabled, MihoWRT still configures `dnsmasq` upstream
while policy is active, but it does not NAT-redirect client DNS/53.

## Safe Reload, Snapshot, And Rollback

Applying policy creates:

```text
/var/run/mihowrt/runtime.snapshot.json
/var/run/mihowrt/always_proxy_dst.snapshot
/var/run/mihowrt/always_proxy_src.snapshot
/var/run/mihowrt/direct_dst.snapshot
```

The snapshot records applied UCI settings, parsed Mihomo runtime fields,
effective route table/priority, source interfaces, fake-ip state, source
list fingerprints, and copies of the effective policy list files after
remote lists are merged.

Reload behavior:

- If policy is disabled in UCI, reload cleans runtime state and leaves
  the system clean.
- If no valid snapshot exists and live runtime state exists, reload
  refuses in-place changes. This avoids losing track of nft, route, and
  DNS state.
- If no snapshot exists and no live runtime state exists, reload applies
  from a clean state.
- If a valid snapshot exists, reload applies new state. If apply fails,
  MihoWRT restores the previous snapshot.
- If route table/priority changes during reload, old managed route/rule
  are removed only after new state is applied.

This is a safety-oriented reload, not a single kernel-atomic transaction
across nftables, policy routing, and dnsmasq. The code favors rollback
and refusing unsafe reloads over guessing.

## Crash Recovery

`/etc/init.d/mihowrt-recover` runs before the main service on boot. It
calls:

```sh
/usr/bin/mihowrt recover
```

Recovery checks whether live runtime state exists:

- nft table `mihowrt`
- route state file and managed policy route/rule
- DNS backup or hijacked `dnsmasq` state

If state exists, recovery runs cleanup. This handles router reboot or
power loss after MihoWRT changed DNS/routing state but before normal
service stop cleanup could run.

## Commands

Main helper:

```sh
/usr/bin/mihowrt prepare
/usr/bin/mihowrt cleanup
/usr/bin/mihowrt recover
/usr/bin/mihowrt reload
/usr/bin/mihowrt reload-policy
/usr/bin/mihowrt service-running
/usr/bin/mihowrt service-ready
/usr/bin/mihowrt validate
/usr/bin/mihowrt run-service
/usr/bin/mihowrt init-layout
/usr/bin/mihowrt read-config
/usr/bin/mihowrt apply-config /tmp/candidate.yaml
/usr/bin/mihowrt apply-config-contents '<yaml>'
/usr/bin/mihowrt status-json
/usr/bin/mihowrt logs-json 200
/usr/bin/mihowrt status
```

Service wrapper:

```sh
/etc/init.d/mihowrt start
/etc/init.d/mihowrt stop
/etc/init.d/mihowrt restart
/etc/init.d/mihowrt reload
/etc/init.d/mihowrt apply
```

Common usage:

```sh
# Validate current config and policy
/usr/bin/mihowrt validate

# Apply direct file edits safely if service is running
/etc/init.d/mihowrt apply

# Reload only policy/list/UCI changes
/etc/init.d/mihowrt reload

# Read machine-friendly diagnostics
/usr/bin/mihowrt status-json | jq .
```

## Installer Mechanics

The installer is transaction-oriented. It tries to leave networking
usable even if package install, Mihomo update, service restart, or state
restore fails.

For package install/update:

1. Detect whether MihoWRT was enabled and running.
2. Seed metadata into an old DNS backup if needed.
3. Back up:
   - `/opt/clash/config.yaml`
   - `/etc/config/mihowrt`
   - policy list files
   - `/etc/mihowrt/dns.backup`
4. Hold required dependencies with an APK virtual package when supported.
5. Restore system DNS/routing defaults before update.
6. Download latest `luci-app-mihowrt-*.apk`.
7. Download and stage latest Mihomo core for detected architecture.
8. Install Mihomo core.
9. Create skip-start marker so package postinst cannot auto-start the
   service mid-transaction.
10. Install or reinstall APK.
11. Verify required packages are present.
12. Stop any service instance that auto-started anyway.
13. Restore user config and policy files.
14. Restore enabled/running state from before update.

If reinstall fails, the installer tries to restore previous Mihomo core,
user files, DNS, route state, and service state. If a backup directory
or kernel backup cannot be safely removed after a failure, it is
preserved under `/tmp` and the path is printed.

For kernel-only mode, the installer updates `/opt/clash/bin/clash`
without reinstalling the APK.

For remove mode, it stops service, runs cleanup, restores DNS/routing,
removes Mihomo core, removes package, and removes MihoWRT user/runtime
state.

Network fetch behavior can be tuned:

```sh
FETCH_RETRIES=3
FETCH_CONNECT_TIMEOUT=10
FETCH_MAX_TIME=60
SERVICE_START_TIMEOUT=5
```

## Build From OpenWrt SDK

This repository is a package directory. With the SDK next to the repo:

```sh
cd ~/openwrt/openwrt-sdk-25.12.3-x86-64_gcc-14.3.0_musl.Linux-x86_64
rm -rf package/luci-app-mihowrt
mkdir -p package/luci-app-mihowrt
rsync -a --delete --exclude='.git' ../mihowrt/ package/luci-app-mihowrt/
./scripts/config -m PACKAGE_luci-app-mihowrt
make defconfig
make package/luci-app-mihowrt/clean
make package/luci-app-mihowrt/compile V=s -j"$(nproc)"
```

Result path for the x86/64 SDK:

```text
bin/packages/x86_64/base/luci-app-mihowrt-<version>-r1.apk
```

The package declares `PKGARCH:=all`, so the APK payload is noarch inside
the same OpenWrt release line. Kernel modules and dependencies still
come from the target SDK/repository.

## Repository Layout

```text
Makefile
  OpenWrt package definition.

install.sh
  Router-side installer/updater/remover.

rootfs/etc/config/mihowrt
  Default UCI settings.

rootfs/etc/init.d/mihowrt
  Main procd service wrapper.

rootfs/etc/init.d/mihowrt-recover
  Boot-time cleanup/recovery hook.

rootfs/usr/bin/mihowrt
  Runtime orchestration entrypoint.

rootfs/usr/lib/mihowrt/constants.sh
  Shared paths and nft/routing constants.

rootfs/usr/lib/mihowrt/helpers.sh
  Validation, config parsing, process checks, and common helpers.

rootfs/usr/lib/mihowrt/runtime.sh
  tmpfs layout for Mihomo cache paths.

rootfs/usr/lib/mihowrt/dns.sh
  dnsmasq backup, apply, restore, and fallback recovery.

rootfs/usr/lib/mihowrt/nft.sh
  nftables generation and policy routing helpers.

rootfs/usr/lib/mihowrt/policy.sh
  Runtime apply/cleanup/reload/snapshot/status logic.

rootfs/usr/lib/mihowrt/lists.sh
  Policy list counting and validation integration.

rootfs/www/luci-static/resources/view/mihowrt/
  LuCI pages: Mihomo config, traffic policy, diagnostics.

rootfs/www/luci-static/resources/mihowrt/
  Shared LuCI backend, exec, UI, and Ace helpers.

tests/
  Shell and Node tests for installer, runtime, policy, DNS, and LuCI
  helpers.
```

## Known Limits And Design Choices

- IPv6 traffic is not intercepted by MihoWRT policy rules.
- `localv4` destinations are excluded before manual policy matching.
  `:port` entries do not override that safety exclusion.
- Port-qualified policy entries are direct nft rules, not interval set
  elements. Very large port-qualified lists will create more nft rules
  than IP-only lists.
- `dnsmasq` backup is persisted in `/etc/mihowrt/dns.backup` by design
  so DNS can be restored after power loss.
- Reload is rollback-capable but not a single atomic transaction across
  nftables, policy routing, and dnsmasq.
- The installer uses latest GitHub releases for package and Mihomo core.
  It does not pin release checksums in this repository.
