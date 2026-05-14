# MihoWRT

MihoWRT is a LuCI package and OpenWrt runtime layer for running
Mihomo on APK-based OpenWrt systems.

Mihomo remains the proxy engine. MihoWRT does not replace Mihomo
rules, proxy groups, providers, DNS engine, or dashboard. MihoWRT owns
router integration:

- LuCI pages for config editing, service control, traffic policy, and diagnostics.
- Mihomo config validation before writes become active.
- nftables TPROXY policy for selected IPv4 traffic.
- policy routing for marked packets.
- optional client DNS/53 redirect to Mihomo DNS.
- dnsmasq upstream switch while policy is active.
- tmpfs placement for write-heavy Mihomo cache paths.
- runtime snapshots, rollback, boot recovery, and cleanup.
- installer flow for package update, Mihomo core update, rollback, and user-state preservation.

Current scope is intentionally IPv4 and fake-ip focused. The bundled
Mihomo config has IPv6 disabled, and MihoWRT nftables policy matches
IPv4 only. `dns.enhanced-mode: fake-ip` is required because MihoWRT
uses fake-ip destinations as part of the interception model.

## Requirements

Package dependencies:

```text
luci-base
jq
nftables
kmod-nft-tproxy
wget-any
curl
```

Runtime also expects normal OpenWrt tools and services:

```text
uci
ip
dnsmasq
procd
logread
```

`pgrep` is optional. MihoWRT uses it only as a fallback when the Mihomo
pid file is missing.

The installer downloads the Mihomo core binary separately. The APK does
not bundle `/opt/clash/bin/clash`.

## Install And Update

Run on the router:

```sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

or:

```sh
curl -fsSL https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

Interactive actions:

```text
1. Install/update package + kernel
2. Install/update kernel only
3. Remove package + kernel
4. Stop
```

In installer text, "kernel" means the Mihomo core binary at
`/opt/clash/bin/clash`, not the Linux/OpenWrt kernel.

Non-interactive mode:

```sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | MIHOWRT_ACTION=package sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | MIHOWRT_ACTION=kernel sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | MIHOWRT_ACTION=remove sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | MIHOWRT_ACTION=stop sh
```

Accepted action aliases:

```text
package: package, pkg, install, update, 1
kernel:  kernel, core, 2
remove:  remove, delete, uninstall, 3
stop:    stop, cancel, 4
```

Useful installer variables:

```text
MIHOWRT_FORCE_REINSTALL=1
FETCH_RETRIES=3
FETCH_CONNECT_TIMEOUT=10
FETCH_MAX_TIME=60
SERVICE_START_TIMEOUT=5
```

The installer is transaction-oriented. It backs up user config, stops
and cleans runtime state before package changes, stages the Mihomo
binary, prevents package postinst from starting the service in the
middle of the transaction, restores user files, then restores previous
enabled/running state.

Package mode downloads the latest `luci-app-mihowrt-*.apk` from this
project release and the latest Mihomo binary from `MetaCubeX/mihomo`.
Kernel-only mode updates only `/opt/clash/bin/clash`.

## Installed Files

Main files:

```text
/etc/config/mihowrt
/etc/init.d/mihowrt
/etc/init.d/mihowrt-recover
/usr/bin/mihowrt
/usr/bin/mihowrt-read
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

Mihomo core:

```text
/opt/clash/bin/clash
```

Mihomo dashboard UI is not stored in this repository. The default
Mihomo config uses Mihomo's `external-ui-url` support, so Mihomo
downloads dashboard files into the configured `external-ui` path.

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
/lib/upgrade/keep.d/mihowrt
```

The APK declares these conffiles:

```text
/etc/config/mihowrt
/opt/clash/config.yaml
/opt/clash/lst/always_proxy_dst.txt
/opt/clash/lst/always_proxy_src.txt
/opt/clash/lst/direct_dst.txt
```

APK protected paths and sysupgrade keep rules preserve MihoWRT user
state across package updates and OpenWrt upgrades with config
preservation.

## Source Of Truth

MihoWRT has three persistent user inputs.

### Mihomo Config

Path:

```text
/opt/clash/config.yaml
```

This is the real Mihomo YAML config. MihoWRT reads only fields needed
for router integration:

```text
dns.listen
dns.enhanced-mode
dns.fake-ip-range
port
socks-port
mixed-port
redir-port
allow-lan
bind-address
tproxy-port
routing-mark
external-controller
external-controller-tls
external-controller-unix
external-controller-pipe
external-controller-cors
external-doh-server
secret
tls
external-ui
external-ui-name
external-ui-url
```

Full Mihomo syntax remains Mihomo responsibility:

```sh
/opt/clash/bin/clash -d /opt/clash -f /opt/clash/config.yaml -t
```

### UCI Policy Config

Path:

```text
/etc/config/mihowrt
```

Default settings:

```text
config settings 'settings'
	option policy_mode 'direct-first'
	list source_network_interfaces 'br-lan'
	option dns_hijack '1'
	option disable_quic '1'
	option subscription_url ''
```

Optional route settings can be added:

```text
option route_table_id ''
option route_rule_priority ''
```

Empty route table/priority means auto-select. Explicit values are
validated and never overwrite unrelated router state.

### Policy Lists

Paths:

```text
/opt/clash/lst/always_proxy_dst.txt
/opt/clash/lst/always_proxy_src.txt
/opt/clash/lst/direct_dst.txt
```

`direct-first` mode uses `always_proxy_dst.txt` and
`always_proxy_src.txt`. Only matching traffic goes to Mihomo, plus
fake-ip traffic.

`proxy-first` mode uses `direct_dst.txt`. Non-local TCP/UDP traffic goes
to Mihomo unless the destination list returns it to direct routing.

Runtime snapshots in `/var/run/mihowrt` are not source of truth. They
describe active state for diagnostics, safe reload, rollback, and
cleanup.

## LuCI Model

MihoWRT adds pages under `Services -> MihoWRT`.

### Mihomo Config

Edits raw `/opt/clash/config.yaml`.

Important actions:

- `Validate & Apply Config` validates through Mihomo, validates MihoWRT
  runtime fields, writes the config only after both checks pass, then
  restarts MihoWRT if it was running.
- `Fetch Subscription` downloads subscription text into the editor but
  does not save it until validation/apply.
- `Save Subscription URL` writes only the URL setting.
- service start/stop/autostart buttons call the init script.
- dashboard button opens the configured Mihomo external UI.

Config apply uses a temp file under `/tmp`. The live config is not
overwritten until validation passes.

### Traffic Policy

Edits `/etc/config/mihowrt` and policy list files.

`Save` writes values to disk. `Save & Apply` follows normal LuCI apply
flow. If only policy list files changed and service is running, MihoWRT
reloads policy after saving. If service is stopped, changes apply on
next start.

`Update Remote Lists` fetches remote list URLs and compares the resolved
effective lists with the active snapshot. nftables is reloaded only when
effective content changed.

### Diagnostics

Reads service state, active snapshot, desired config, parse errors, DNS
backup state, route state, and MihoWRT logs. There is no background
diagnostic polling; refresh is explicit.

## Backend Security Model

LuCI uses two backend executables:

```text
/usr/bin/mihowrt-read
/usr/bin/mihowrt
```

`mihowrt-read` exposes read-only commands:

```text
read-config
subscription-json
service-state-json
status-json
logs-json
```

It also restricts temporary config reads to `/tmp/mihowrt-config.*`.

Mutating operations use `/usr/bin/mihowrt` and require LuCI write ACL:

```text
apply-config
set-subscription-url
fetch-subscription
update-policy-lists
restart-validated-service
init script actions
```

This split keeps ordinary read refreshes away from the write-capable
orchestrator surface.

## Service Lifecycle

OpenWrt starts MihoWRT through:

```sh
/etc/init.d/mihowrt start
```

Main procd command:

```sh
/usr/bin/mihowrt run-service
```

Start flow:

1. refuse installer mid-transaction auto-start when skip marker exists.
2. recover stale state from previous crash or power loss.
3. validate Mihomo config with `clash -d /opt/clash -f ... -t`.
4. validate MihoWRT runtime config.
5. cleanup stale nft, route, DNS, and snapshot state.
6. start Mihomo with `-d /opt/clash -f /opt/clash/config.yaml`.
7. wait until Mihomo DNS and TPROXY listeners are ready.
8. apply policy route, nftables rules, DNS state, and runtime snapshot.
9. wait for Mihomo exit.
10. cleanup runtime state on stop or process exit.

Runtime mutations are guarded by a symlink lock:

```text
/var/run/mihowrt/runtime.lock
```

Default lock timeout is 120 seconds and can be changed with
`RUNTIME_LOCK_TIMEOUT`.

## Runtime State And Flash Writes

Write-heavy Mihomo runtime paths are moved to tmpfs:

```text
/opt/clash/ruleset          -> /tmp/clash/ruleset
/opt/clash/proxy_providers  -> /tmp/clash/proxy_providers
/opt/clash/cache.db         -> /tmp/clash/cache.db
```

If real files or directories already exist at the `/opt/clash` paths,
MihoWRT copies them to `/tmp` before replacing them with symlinks.

Normal runtime snapshots stay in tmpfs:

```text
/var/run/mihowrt/runtime.snapshot.json
/var/run/mihowrt/always_proxy_dst.snapshot
/var/run/mihowrt/always_proxy_src.snapshot
/var/run/mihowrt/direct_dst.snapshot
/var/run/mihowrt/route.state
```

One persistent DNS backup is intentional:

```text
/etc/mihowrt/dns.backup
```

It exists so boot recovery can restore dnsmasq after power loss, where
`/tmp` and `/var/run` are gone. The file is written only when needed and
only when content changed.

## Traffic Policy Lists

List files support comments, blank lines, manual entries, and remote
HTTP(S) URLs.

Valid entries:

```text
ip
ip/mask
ip;port
ip/mask;port
;port
http(s)://url
http(s)://url;port
```

Port formats:

```text
443
15-2000
15,443,8443
```

Rules:

- ports must be `1..65535`.
- ranges require `start <= end`.
- comma lists contain concrete ports only.
- mixed `15-20,443` syntax is invalid.
- IPv6 entries are not supported.
- invalid entries are skipped and logged.
- `;` is preferred before ports because `:` belongs to URLs.
- legacy `ip:port`, `ip/mask:port`, and `:port` are accepted and migrated.
- URLs inside remote lists are ignored; remote lists do not recurse.
- remote content is merged into temp effective lists; persistent list files are not rewritten.
- remote fetch failure fails apply/reload. Existing runtime state is restored when snapshot rollback is possible.

Remote list limits:

```text
POLICY_REMOTE_LIST_MAX_BYTES=262144
POLICY_EFFECTIVE_LIST_MAX_BYTES=1048576
POLICY_REMOTE_LIST_FETCH_TIMEOUT=15
POLICY_REMOTE_LIST_FETCH_BUDGET=60
POLICY_REMOTE_LIST_MAX_URLS=32
```

Destination list semantics:

- `always_proxy_dst.txt` matches destination address.
- port-qualified entries match destination port.
- `;port` matches any IPv4 destination on that destination port.
- destination policy applies to client traffic and router-originated output traffic.

Source list semantics:

- `always_proxy_src.txt` matches client/source address.
- port-qualified entries still filter by destination port.
- source policy applies only to prerouting traffic from configured source interfaces.
- source policy does not apply to router-originated output traffic.

Performance model:

- IP/CIDR entries go into nftables interval sets.
- port-qualified entries become direct nftables rules.
- common IP-only lists stay compact; port rules remain explicit and readable.

## nftables And Routing

MihoWRT owns one nftables table:

```text
table inet mihowrt
```

Main sets:

```text
proxy_dst
proxy_src
direct_dst
localv4
source_ifaces
```

Main chains:

```text
dns_hijack
mangle_prerouting
prerouting_policy
mangle_output
proxy_redirect
```

Important order:

1. optional DNS/53 redirect happens first for selected source interfaces.
2. local/reserved IPv4 destinations return before policy matching.
3. already marked packets return to avoid loops.
4. selected TCP/UDP traffic gets intercept mark `0x00001000`.
5. optional QUIC blocking rejects selected UDP/443 before marking.
6. marked packets are TPROXYed to `127.0.0.1:<tproxy-port>`.
7. router-originated output traffic uses destination/fake-ip policy, not source/client policy.

Policy routing:

```sh
ip rule add fwmark 0x00001000/0x00001000 table <table> priority <priority>
ip route replace local 0.0.0.0/0 dev lo table <table>
```

Auto ranges:

```text
table id: 200..252
priority: 10000..10999
```

Effective values are stored in `/var/run/mihowrt/route.state`. Reload
reuses safe managed values and refuses explicit conflicts with foreign
router state.

Mihomo `routing-mark` must not equal MihoWRT intercept mark
`0x00001000`.

## DNS Behavior

MihoWRT has two DNS mechanisms.

### dnsmasq Upstream

While policy is active, MihoWRT points dnsmasq upstream to Mihomo DNS:

```text
dhcp.@dnsmasq[0].server    = <mihomo dns listen as host#port>
dhcp.@dnsmasq[0].cachesize = 0
dhcp.@dnsmasq[0].noresolv  = 1
dhcp.@dnsmasq[0].resolvfile cleared
```

Cleanup restores previous dnsmasq state from runtime backup, persistent
backup, or safe fallback defaults when current state still clearly
points to Mihomo.

### Client DNS/53 Redirect

If `option dns_hijack '1'`, client TCP/UDP port 53 from configured
source interfaces is redirected to Mihomo DNS.

If disabled, dnsmasq upstream still goes through Mihomo while policy is
active, but client DNS/53 packets are not NAT-redirected.

## Safe Reload And Recovery

Reload behavior:

- disabled policy cleans runtime state.
- no snapshot plus live runtime state refuses unsafe in-place reload.
- no snapshot plus no live runtime state applies from clean state.
- valid snapshot applies new state and restores old snapshot on failure.
- old route/rule state is removed only after new state applies.
- remote list update leaves nftables untouched when effective lists did not change.

This is rollback-capable orchestration across nftables, policy routing,
and dnsmasq. It is not a single kernel-atomic transaction.

Boot recovery:

```sh
/etc/init.d/mihowrt-recover
/usr/bin/mihowrt recover
```

Recovery detects managed nftables, route, DNS, and snapshot state. If
stale state exists, cleanup runs before normal service start.

## Commands

Main backend:

```sh
/usr/bin/mihowrt prepare
/usr/bin/mihowrt cleanup
/usr/bin/mihowrt recover
/usr/bin/mihowrt reload
/usr/bin/mihowrt reload-policy
/usr/bin/mihowrt update-policy-lists
/usr/bin/mihowrt migrate-policy-lists
/usr/bin/mihowrt service-running
/usr/bin/mihowrt service-ready
/usr/bin/mihowrt service-state-json
/usr/bin/mihowrt restart-validated-service
/usr/bin/mihowrt validate
/usr/bin/mihowrt run-service
/usr/bin/mihowrt init-layout
/usr/bin/mihowrt read-config
/usr/bin/mihowrt apply-config /tmp/candidate.yaml
/usr/bin/mihowrt apply-config-contents '<yaml>'
/usr/bin/mihowrt subscription-json
/usr/bin/mihowrt set-subscription-url '<url>'
/usr/bin/mihowrt fetch-subscription '<url>'
/usr/bin/mihowrt status-json
/usr/bin/mihowrt logs-json 200
/usr/bin/mihowrt status
```

Read-only backend:

```sh
/usr/bin/mihowrt-read read-config
/usr/bin/mihowrt-read read-config /tmp/mihowrt-config.test
/usr/bin/mihowrt-read subscription-json
/usr/bin/mihowrt-read service-state-json
/usr/bin/mihowrt-read status-json
/usr/bin/mihowrt-read logs-json 200
```

Init script:

```sh
/etc/init.d/mihowrt start
/etc/init.d/mihowrt stop
/etc/init.d/mihowrt restart
/etc/init.d/mihowrt reload
/etc/init.d/mihowrt apply
/etc/init.d/mihowrt update_lists
```

Common diagnostics:

```sh
/usr/bin/mihowrt validate
/usr/bin/mihowrt status-json | jq .
/usr/bin/mihowrt logs-json 200 | jq .
```

## Development

Run local checks:

```sh
bash tests/run.sh
```

The test suite covers shell syntax, shell lint, JavaScript syntax, and
runtime helper tests for installer, backend, config apply, policy,
remote lists, DNS, nft/route helpers, snapshots, LuCI helpers, and
service entrypoints.

No new runtime dependency should be added without a clear router-side
reason. Prefer POSIX/ash-compatible shell, `jq` for JSON, `uci` for UCI,
and nft/ip commands only at orchestration boundaries.

## Build From OpenWrt SDK

With the OpenWrt SDK next to this repository:

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

Example APK path for x86/64 SDK:

```text
bin/packages/x86_64/base/luci-app-mihowrt-<version>-r1.apk
```

The package payload is noarch (`PKGARCH:=all`) inside the same OpenWrt
release line. Kernel modules and dependencies still come from the
target SDK/repository.

## Repository Layout

```text
Makefile
  OpenWrt package definition.

install.sh
  router-side installer, updater, remover, rollback flow.

rootfs/etc/init.d/mihowrt
  procd service wrapper and apply/reload entrypoints.

rootfs/etc/init.d/mihowrt-recover
  boot-time stale runtime cleanup.

rootfs/usr/bin/mihowrt
  write-capable runtime orchestrator and command dispatcher.

rootfs/usr/bin/mihowrt-read
  read-only LuCI backend wrapper.

rootfs/usr/lib/mihowrt/constants.sh
  shared paths, nft constants, route ranges.

rootfs/usr/lib/mihowrt/helpers.sh
  common shell helpers and module loader.

rootfs/usr/lib/mihowrt/validation-core.sh
  primitive validators and numeric helpers.

rootfs/usr/lib/mihowrt/validation-dns.sh
  DNS listen and DNS-related validation.

rootfs/usr/lib/mihowrt/validation-policy.sh
  policy list, port, route, mark, IPv4 validation.

rootfs/usr/lib/mihowrt/validation.sh
  validation module composition.

rootfs/usr/lib/mihowrt/config-io.sh
  Mihomo config read/parse/apply helpers.

rootfs/usr/lib/mihowrt/fetch.sh
  bounded HTTP fetch and subscription helpers.

rootfs/usr/lib/mihowrt/diagnostics.sh
  bounded log JSON helpers.

rootfs/usr/lib/mihowrt/runtime-config.sh
  UCI/YAML runtime config load and validation.

rootfs/usr/lib/mihowrt/runtime-probe.sh
  service, pid, port, and readiness probes.

rootfs/usr/lib/mihowrt/runtime.sh
  tmpfs runtime layout for Mihomo cache paths.

rootfs/usr/lib/mihowrt/dns-state.sh
  DNS state serialization helpers.

rootfs/usr/lib/mihowrt/dns.sh
  dnsmasq backup, apply, restore, recovery.

rootfs/usr/lib/mihowrt/lists.sh
  policy list migration, remote merge, validation, fingerprints.

rootfs/usr/lib/mihowrt/nft.sh
  nftables batch generation and cleanup.

rootfs/usr/lib/mihowrt/route.sh
  policy route/rule selection, apply, cleanup.

rootfs/usr/lib/mihowrt/runtime-snapshot.sh
  active runtime snapshot, readiness, desired-state comparison.

rootfs/usr/lib/mihowrt/policy.sh
  prepare/apply/reload/update/rollback orchestration.

rootfs/usr/lib/mihowrt/runtime-status.sh
  status JSON and human-readable runtime status.

rootfs/www/luci-static/resources/mihowrt/
  shared LuCI backend, exec, config, UI, and Ace helpers.

rootfs/www/luci-static/resources/view/mihowrt/
  LuCI pages: config, policy, diagnostics.

tests/
  shell and Node tests.
```

## Known Limits

- IPv6 traffic is not intercepted.
- local/reserved IPv4 destinations return before manual policy matching.
- `;port` entries do not override local/reserved destination exclusion.
- port-qualified policy entries create direct nftables rules, not set elements.
- reload has rollback, but is not one atomic transaction across nftables, route, and dnsmasq.
- latest GitHub releases are used by installer; release checksums are not pinned in this repository.
- hardware behavior still depends on target OpenWrt, nftables, procd, dnsmasq, and Mihomo versions.
