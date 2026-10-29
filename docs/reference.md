# MihoWRT technical reference

[Quick start](../README.md) · [User guide](user-guide.md) · [Development](development.md)

## Provider settings (`x-mihowrt`)

A provider (or you, in the YAML) can set router options in a top-level
`x-mihowrt` section. It is removed from the config Mihomo gets:

```yaml
x-mihowrt:
  disable-quic: true            # Block QUIC for proxied traffic
  dns-hijack: true              # Redirect client DNS to Mihomo
  bypass-ntp: true              # Time sync without Mihomo
  bypass-subscription-dns: true # Subscription server without Mihomo
  block-client-ipv6: true       # direct-first: reject client IPv6 that bypasses Mihomo
  lists-interval: 24            # remote list refresh, hours (0-8760)
  proxy-ips:                    # "Only selected" mode: always via Mihomo
    - https://provider.example/telegram.txt
    - 91.108.4.0/22
  direct-ips:                   # "All traffic" mode: bypass Mihomo
    - https://provider.example/ru.txt
```

Booleans: `true/false/yes/no/on/off/1/0`. Block style only; an invalid or
unknown child key is ignored with a warning in the log. An unsupported top-level `x-mihowrt` form (flow mapping, sequence or scalar other than null) rejects the config instead. Without a key the router setting applies. NetBird, client
interfaces, device lists and the update period are never provider-controlled.

On the *Traffic* page a provider value is shown read-only with *Set by your
provider*; *Use my own value* switches that one setting to your value (UCI
`list provider_override`), even when the provider later drops or re-adds the
key. A provider list offers *Provider list* (default), *Provider list + mine*
and *Only mine* (UCI `dst_list_source` / `direct_list_source`). Your list file
is never deleted; with *Provider list* the page says how many of your entries
are not applied. Provider values are kept in tmpfs
(`/tmp/mihowrt/config.yaml.profile`), never in UCI or flash.

## How it works

### Router-owned Mihomo settings

Runtime generation never rewrites your YAML (`/opt/clash/config.yaml`); subscription install, editor save and restore replace it atomically. At start MihoWRT
writes `/tmp/mihowrt/config.yaml`: a copy with these keys replaced by a
managed section at the end:

```yaml
tproxy-port: 7894
routing-mark: 2
allow-lan: true          # needed for the IPv6 TPROXY socket
bind-address: "*"
tun:
  enable: false
log-level: <error|silent|warning|info|debug> # owned by UCI mihomo_log_level, default error
profile:                 # selected servers and fake-ip mappings survive restarts
  store-selected: true
  store-fake-ip: true
external-controller: <LAN IP>:9090
external-controller-unix: /tmp/clash/mihomo.sock
secret: "<generated, /etc/mihowrt/api_secret>"
external-ui: ui          # only when the optional dashboard is enabled
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/download/v3.29.1/dist-no-fonts.zip"
# external-ui and external-ui-url are omitted when the dashboard is disabled
# and inside dns: enable, listen 0.0.0.0:7874, and fake-ip-range
# 198.18.0.0/16 when enhanced-mode is fake-ip (fake-ip-range6 is dropped)
```

`dns.enhanced-mode`, `ipv6`, `dns.ipv6` and other keys (`mixed-port` …) stay
as you set them. Without a `dns` section MihoWRT adds one: `redir-host`, DoH
servers 1.1.1.1/9.9.9.9/8.8.8.8 for bootstrap, Yandex DoH for direct domains,
and Cloudflare/Google DoH queried through the first proxy group
(`https://dns.google/dns-query#<group>`; plain when the group name has `#`,
`&`, `"` or `\`). Without a `sniffer` section a default one sniffs HTTP
(80, 8080-8880) and TLS (443, 8443); a provider sniffer is never touched.
There is no YAML parser: top-level blocks are replaced line by line, so flow
style (`dns: {…}`, `x-mihowrt: {…}`) is rejected with an error. Changed runtime YAML is validated with `mihomo -t` before it is used; Mihomo's
own error message is shown in LuCI. The result is remembered in
`/var/run/mihowrt/config.ok|config.err` for Diagnostics, so status never runs
the core.

MihoWRT manages `log-level` in `/tmp/mihowrt/config.yaml` based on UCI option `mihomo_log_level` (`silent`, `error`, `warning`, `info`, `debug`, default `error`). Using `error` avoids logging every TCP connection to syslog, protecting logd and diagnostics from CPU and memory exhaustion. Mihomo's external API (`/logs`) and the web dashboard still stream all log levels regardless of this setting.

Geodata (GeoIP, GeoSite, ASN) follows your YAML: `geo-auto-update`,
`geo-update-interval` and `geox-url` are not changed by MihoWRT. The files stay
in `/opt/clash`; their update behaviour belongs to Mihomo, not MihoWRT.

### DNS

dnsmasq gets a conf-dir file `/tmp/dnsmasq.<section>.d/mihowrt.conf`:

```text
no-resolv
server=127.0.0.1#7874
server=/<ntp host>/<WAN interface DNS>            # "Time sync without Mihomo"
server=/<subscription host>/<WAN interface DNS>   # "Subscription server without Mihomo"
```

UCI is not modified, so stopping MihoWRT, a crash or a reboot restores your
DNS by removing one tmpfs file. WAN interface DNS servers come from `resolv.conf.auto` and
are refreshed on WAN reconnects (hotplug). Global `server` entries you set
yourself in *DHCP and DNS* keep working next to Mihomo, so some queries bypass
it; Diagnostics warns about them. Client DNS on port 53 is redirected to
Mihomo for IPv4 and IPv6 (*Redirect client DNS to Mihomo*).

While a subscription updates (toggle *Subscription server without Mihomo*),
the addresses of its host are put into a short-lived nft set so the router
downloads it directly in either mode; they are removed right after the
download. Only the router's own traffic is affected, not LAN clients.

### Validation and memory

Mihomo config tests use a soft `GOMEMLIMIT` of half RAM for the installed core, a quarter RAM for a candidate core during update. A successful test is keyed by runtime YAML hash and core version in `/var/run/mihowrt/config.tested`; start can reuse it until reboot or a key change. Reload reuses an existing runtime config/profile when its saved generator input key matches; after generation, byte-identical runtime YAML also skips validation/reload. This reduces repeated work, not the memory needed for a genuinely new large config.

### Self-healing

- **Watchdog:** every 15 s MihoWRT asks Mihomo to resolve `openwrt.org`
  through its API. After 3 failures in a row (about 45–60 s) it removes the
  DNS file, nft table and routes, so the network works directly, and keeps
  probing; the first good answer applies the policy again. If the Mihomo API
  itself does not answer, the service exits and procd restarts it after 5 s.
  After 5 failed restarts in an hour procd gives up and the router stays
  direct until the WAN comes up again (hotplug restarts an enabled service)
  or you press Start.
- **Stop** is synchronous: it returns after DNS, nft and routes are clean
  (procd `term_timeout 30`). It is also sticky: WAN hotplug does not start
  a stopped service again until Start or a reboot (`/var/run/mihowrt/stopped`).
- **Boot:** a reboot clears runtime state; no separate recovery hook is needed.
- **Memory:** Mihomo runs with `GOMEMLIMIT` = half of RAM. This is the Go
  runtime's soft heap target: the garbage collector works harder near it
  instead of letting the heap double before collecting. It reduces OOM kills on
  small routers. It is not a hard cap.
- **Config changes** are hot-reloaded through the API. If Mihomo rejects the
  new config, the previous one is restored.
- **Updates keep traffic flowing:** the nft table is replaced in one kernel
  transaction (packets see the old or the new ruleset, never none) and an
  identical ruleset is not applied again; a subscription with the same bytes
  is not written or reloaded (`unchanged`); when only `x-mihowrt` changed,
  Mihomo is not reloaded; dnsmasq restarts only when its file changes or the
  DNS mode switches (to drop cached fake-IP answers). The remaining gap is
  Mihomo's own reload, which pauses new connections until rules and
  providers are loaded (duration depends on the config and router).

### nftables and routing

Table `inet mihowrt` marks selected packets with `0x08000000`. Other mark bits
are preserved, so the table coexists with NetBird (`0x1BD00` namespace) and
zapret (`0x40000000`, `0x20000000`). Policy rules automatically use priorities **50–99** and a free local table in **200–252** (saved in `/var/run/mihowrt/route.state`). They precede typical NetBird (105/110) and mwan3 rules. An `ip rule` and, when kernel IPv6 is enabled, an `ip -6 rule` send marked
packets to that table, and TPROXY hands them to Mihomo on
`127.0.0.1:7894` / `[::1]:7894`. Local destinations (`fib daddr type local`),
private ranges, DNS, replies to inbound connections, Mihomo's own traffic (low-byte routing mark 2) and, optionally,
NTP are never intercepted. Networks connected to the router (routes without
`via` in the main table: LAN, guest, IoT, delegated IPv6 prefixes) are never
intercepted either, so they cannot be sent into TPROXY or bypass the firewall
zones; WAN link subnets keep their normal handling. Incoming NetBird traffic is never touched; outbound
NetBird transport is captured only with *Route outbound NetBird through proxy*.
Management, signal, relay, ICE and WireGuard transport then follow your Mihomo rules (they may still go DIRECT); data-plane traffic stays direct.

The direct mark is `0x04000000`; the intercept mark is `0x08000000`. The NetBird mark must not overlap either. Network refreshes skip unchanged connected-prefix/DNS inputs; the applied nft ruleset is compared by hash. Hotplug events are coalesced rather than queued independently.

In *All traffic via proxy* (proxy-first), router-originated traffic is also routed to Mihomo through the `mangle_output` catch-all. This includes WireGuard client tunnels, DDNS scripts (where `ip_source=web` resolves to the proxy IP), and Tailscale traffic. To keep such services direct, add their endpoints to `direct_dst` (*Addresses always direct*).

Client interfaces with fw4 input policy set to `REJECT` (such as isolated guest or IoT zones) would normally reject redirected DNS (port 7874) and intercepted TPROXY traffic at the fw4 input chain before it reaches Mihomo. To maintain connectivity for these zones, `nft_apply` writes `/usr/share/nftables.d/chain-pre/input/30-mihowrt.nft` to accept packets matching the intercept mark or redirected DNS port before zone rules drop them. The file is written only when content changes (preventing flash wear), reloads fw4 on change, and is removed on service stop, disable, and uninstall.

### Hardware/software flow offloading

MihoWRT needs no offloading settings. Proxied connections end at Mihomo on the
router, and Mihomo's outbound traffic is router-originated, so neither passes
the forward flowtable. Offloading speeds up only direct traffic. Connections
opened before MihoWRT started (or before a list change) may stay offloaded
direct until they reconnect. With zapret, keep zapret's own offload exclusions.

### Scheduled updates

One cron line at a per-router random minute runs `mihowrt auto-update` hourly.
With *Update automatically* on (default) the subscription is updated at the
period the provider sets in the `profile-update-interval` header; without the
header there are no automatic updates (the provider's choice), only *Update
now*. Remote lists are refreshed when due. Cron uses the same background-job slot as LuCI; if another operation is running, the tick skips it. Remote-list check timestamps live in tmpfs (cache mtime is the fallback after reboot), and the crontab is written only if its contents change.

## Command line

```text
mihowrt status-json | service-state-json | profile-json | diagnostics-json | logs-json [lines]
mihowrt subscription-json | set-subscription <url> <0|1> | update-subscription [url]
mihowrt lists-json | apply-lists <dst-tmp|-> <src-tmp|-> <direct-tmp|-> <direct-src-tmp|-> | update-lists
mihowrt read-config [tmp] | runtime-config | save-config <tmp> | restore-config
mihowrt core-update [--file /tmp/mihomo[.gz]|/tmp/mihomo-linux-*] | core-version-json
mihowrt proxies-json | select-proxy <group> <name|''> | group-delay <group> | dashboard-json
mihowrt job-start <op> [args] | job-status [id]
mihowrt auto-update | net-refresh | recover | reload | migrate | uninstall
mihowrt prepare | run-service | wait-stopped
/etc/init.d/mihowrt start | stop | restart | reload | enable | disable
```

`prepare`, `run-service`, `wait-stopped`, `recover` and `migrate` are lifecycle helpers, not ordinary start/stop commands. Use the init script for service control.

`job-start` operations (not separate top-level CLI commands):

```text
connect <url> | update-subscription [url] | update-lists
apply-lists <dst-tmp|-> <src-tmp|-> <direct-tmp|-> <direct-src-tmp|->
save-config <tmp> | restore-config | core-update | auto-update
dashboard-install | dashboard-remove | service <start|stop|restart>
```

For example, `mihowrt job-start dashboard-install` returns a job ID; inspect it with `mihowrt job-status <id>`. Install requires a running service; `dashboard-remove` disables and removes the panel. `dashboard-json` includes `enabled`, `installed`, `size` (bytes), controller connection data and secret: keep its output private. Jobs serialize LuCI/cron operations; their output/error logs keep at most 64 KB each. Temporary upload paths for `save-config` and `apply-lists` must use `/tmp/mihowrt-config.*` and `/tmp/mihowrt-policy-list.*` respectively.

`update-subscription [url]` saves a new URL only after a successful download and validation. `core-update --file` accepts an architecture-compatible local gzip or executable, only as a regular non-symlink file named `/tmp/mihomo`, `/tmp/mihomo.gz` or `/tmp/mihomo-linux-*` (the release asset name), so no file a LuCI user can write runs as root. It skips the release digest check with a warning, then uses the normal version/config test and atomic replacement. Verify local files yourself. Online update checks the GitHub release digest when available; API fallback via the latest-release redirect has no digest and logs a warning. Download stalls are bounded (below 2048 bytes/s for 60 s, two retries), not a fixed five-minute total.

`mihowrt uninstall` stops the service and removes DNS/nftables/routes, its cron entry, runtime state, core, dashboard, geodata, `/etc/mihowrt/subscription.json` (subscription metadata), `/etc/mihowrt/cache.db` (saved proxy selection/fake-IP cache) and `/etc/mihowrt/policy-cache/` (remote lists). Your YAML and `config.yaml.bak`, policy list files, UCI settings, API secret and `/etc/mihowrt/hwid` stay. Keeping HWID lets the provider recognise the same device after reinstall. Package removal calls the same cleanup. It does **not** remove the package: use the installer, `apk del` or `opkg remove` (see [README](../README.md#remove)).

### Core asset selection

Read `DISTRIB_ARCH` on the router with `grep '^DISTRIB_ARCH=' /etc/openwrt_release`; do not use the PC's architecture. The first matching row below follows `core_arch()` and `core_asset_names()` in `rootfs/usr/lib/mihowrt/core.sh`. Asset names are `mihomo-linux-<suffix>-<tag>.gz` (for example `mihomo-linux-arm64-v1.19.33.gz`). Where alternatives are listed, the updater tries them in order; availability depends on the Mihomo release.

| OpenWrt `DISTRIB_ARCH` pattern | Asset suffix(es), in order |
|---|---|
| `aarch64_*` | `arm64` |
| `x86_64` | `amd64-compatible`, `amd64-v1`, `amd64` |
| `i386_*` | `386`, `386-softfloat` |
| `riscv64_*` | `riscv64` |
| `loongarch64_*` | `loong64-abi1`, `loong64-abi2`, `loong64` |
| `mips64el_*` | `mips64le` |
| `mips64_*` | `mips64` |
| `mipsel_*hardfloat*` | `mipsle-hardfloat` |
| other `mipsel_*` | `mipsle-softfloat` |
| `mips_*hardfloat*` | `mips-hardfloat` |
| other `mips_*` | `mips-softfloat` |
| `arm_*neon-vfp*` | `armv7` |
| other `arm_*neon*` or `arm_*vfp*` | `armv6` |
| other `arm_*` | `armv5` |

Other architecture names are not automatically supported. A local `--file` bypasses automatic asset selection, not compatibility testing. Keep the package filenames for checksum verification; the local core can be named `mihomo.gz`. The updater does not delete a user-supplied `--file`: remove it yourself afterwards to reclaim tmpfs.

### Flash budget and checks

100 MB+ free flash is a safe budget, not the installer's hard minimum. The core is about 20 MB compressed and up to about 55 MB unpacked, architecture/version dependent; updates need old and new cores side by side. Compressing overlays (UBIFS/JFFS2) can store it near its compressed size and need less physical flash. Geodata and the optional dashboard are extra.

`install.sh` checks for 2048 KB free on `/opt/clash` for packages. `core.sh` checks free space beside the core ≥ source/download size + 4194304 bytes (4 MB); on an uncompressed filesystem that estimate may be insufficient, so an unpack/copy failure aborts without replacing the installed core. The compressed online download is in tmpfs and is deleted after unpacking, before candidate validation; an offline source file stays until you remove it.

## Files

| Path | Purpose |
|---|---|
| `/etc/config/mihowrt` | Settings (UCI) |
| `/etc/mihowrt/api_secret` | Mihomo controller secret (root-only, mode 600) |
| `/opt/clash/config.yaml` | Your Mihomo YAML (backup: `config.yaml.bak`); both retained on removal |
| `/opt/clash/lst/*.txt` | Policy lists (`direct_src.txt`: devices always direct) |
| `/opt/clash/bin/clash` | Mihomo core |
| `/etc/mihowrt/hwid` | Device ID retained on removal, so a reinstall keeps the provider identity |
| `/etc/mihowrt/subscription.json` | Subscription metadata; removed by uninstall/package removal |
| `/etc/mihowrt/cache.db` | Persisted proxy selection/fake-IP cache; removed by uninstall/package removal |
| `/etc/mihowrt/policy-cache/` | Remote-list cache on flash; removed by uninstall/package removal |
| `/opt/clash/ui/` | Optional dashboard on flash |
| `/tmp/clash/` | Runtime rulesets, providers, cache.db and controller socket |
| `/opt/clash/proxies`, `/opt/clash/rules` | Links to `/tmp/clash/` (RAM): cache of providers without `path`. Keep your own `type: file` provider files elsewhere, e.g. `/opt/clash/my/`. An existing folder with any file other than a Mihomo cache file (32 hex digits) is left on flash, unlinked, with a log warning; uninstall removes only the links |
| `/var/run/mihowrt/` | Health, job state, locks, network fingerprint and config test stamp (tmpfs) |
| `/usr/share/nftables.d/chain-pre/input/30-mihowrt.nft` | fw4 input include admitting intercepted TPROXY and redirected DNS from guest/isolated zones |
| `/tmp/mihowrt/config.yaml` | Generated runtime config (`.profile`: mode and provider settings) |

## Security notes

Packaged entrypoints ignore test-seam variables, proxy and curl environment variables (`https_proxy`, `CURL_CA_BUNDLE`, `SSL_CERT_*` and similar) and use a fixed `PATH`. `LD_PRELOAD` set by a holder of the rpcd write ACL is out of scope: that ACL is root-equivalent on the router, as for every LuCI app.

## Known limits

- Dumb AP mode: if the default route is via the LAN bridge, MihoWRT treats that bridge as WAN and does not exclude its non-RFC1918 connected subnets. This follows the connected-network algorithm; do not assume AP mode has the same exclusions as routed LAN mode.
- RAM: 128–256 MB is for small YAML. An 8 MB fixture OOMed on 128 MB in all tested builds, including 0.10, and on 256 MB; 512 MB passed. Sizes between were not measured. The 8 MB upload limit is not a capacity guarantee. Core updates succeeded on 128 MB in the VM with only about 6–8 MB MemAvailable at the low point; this is not a physical-router guarantee.
- The read-only LuCI access (`mihowrt-read`) exposes the Mihomo YAML (which holds
  provider credentials), the YAML passed to Mihomo (*Show the YAML passed to
  Mihomo*, controller secret hidden) and the subscription link to every LuCI
  user with read access. Give such access only to people you trust with them.
- Connected-network exclusions read only the main routing table, not mwan3 or
  other policy tables. Public VPN routes without `via` with prefixes at least
  /16 (IPv4) or /32 (IPv6) are treated as local and go direct through the tunnel.
- IPv6 fake-IP is not used. IPv6 destinations are handled by the lists and by
  the *All traffic* mode.
- Proxy-first mode captures router-originated traffic: WireGuard clients, DDNS with `ip_source=web` (which registers the proxy IP), and Tailscale are routed through Mihomo unless their server and endpoint IPs/domains are explicitly placed in *Addresses always direct* (`direct_dst`).
- Fake-IP bypass of rebind protection and guest isolation: With fake-IP DNS, clients receive synthetic addresses from `198.18.0.0/16`. If Mihomo routing rules send private subnets `DIRECT` (e.g. `GEOIP,private,DIRECT` or `IP-CIDR,192.168.0.0/16,DIRECT`), Mihomo resolves the target hostname itself and connects from the router via local output (`OUTPUT` chain), bypassing dnsmasq DNS rebind protection and fw4 guest-to-LAN forward isolation.
- Clients using DoH/DoT (browser DoH, Android Private DNS) bypass Mihomo DNS,
  so fake-IP based routing does not apply to them.
- The QEMU VM cannot test hardware offloading or real NetBird peers.
- The client IPv6 block exists only while MihoWRT policy is active: stop and
  watchdog fail-open remove it. Connections already offloaded before a policy
  change can continue until their flowtable entries expire; this is not a
  persistent kill-switch or a kernel IPv6 disable. Client IPv4 → Mihomo → an IPv6
  node stays valid and is not affected; do not use `ipv6: false` as the trigger
  for the block, the `block-client-ipv6` flag is the only switch.
- Device headers (HWID, model) are sent only over HTTPS, but curl repeats them
  if the provider redirects to another HTTPS host.
- Updating the Mihomo core needs free flash for the new unpacked binary next
  to the old one (the compressed download is staged in tmpfs); if the flash fills up, the update stops and the current core
  is kept.
- Provider list URLs are checked before download only; curl follows redirects.

Open and deferred issues: [open-issues.md](open-issues.md).

### OpenWrt 24.10

Tested on OpenWrt 24.10.8 in the VM (kernel 6.6, nft 1.1.1, BusyBox `ip` without iproute2): install via the installer, upgrade and removal with opkg, start/stop/restart, the network acceptance rows, LuCI pages and jobs, and core update behave as on 25.12. Differences:

- 0.11.0 is the first `.ipk` release. Upgrading from a self-built 0.10.x `.ipk` deletes the core and leaves the service stopped (the old package's removal script runs on upgrade); run `mihowrt core-update` and start the service once.
- `opkg install --force-reinstall` is a removal plus an install: the core is deleted and the service stops. Use the installer or a plain `opkg install` instead; reinstalling the same version with plain `opkg install` does nothing.
- opkg prints `Collected errors: resolve_conffiles: Existing conffile … will be placed at …-opkg` when you have changed `/etc/config/mihowrt`, `config.yaml` or the lists. Your files are kept and the `-opkg` copies are removed afterwards.
- A stopped service prints `ubus call service delete … (Not found)` during upgrade or removal; this is harmless OpenWrt output.
