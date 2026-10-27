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
profile:                 # selected servers and fake-ip mappings survive restarts
  store-selected: true
  store-fake-ip: true
external-controller: <LAN IP>:9090
external-controller-unix: /tmp/clash/mihomo.sock
secret: "<generated, /etc/mihowrt/api_secret>"
external-ui: ui          # only when the optional dashboard is enabled
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"
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
NetBird transport is captured only with *Route outbound NetBird through Mihomo*.

The direct mark is `0x04000000`; the intercept mark is `0x08000000`. The NetBird mark must not overlap either. Network refreshes skip unchanged connected-prefix/DNS inputs; the applied nft ruleset is compared by hash. Hotplug events are coalesced rather than queued independently.

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
mihowrt core-update [--file <path.gz|binary>] | core-version-json
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

For example, `mihowrt job-start dashboard-install` returns a job ID; inspect it with `mihowrt job-status <id>`. Install requires a running service; `dashboard-remove` disables and removes the panel. `dashboard-json` includes `enabled`, `installed`, `size` (bytes), controller connection data and secret: keep its output private. Jobs serialize LuCI/cron operations; their output/error logs keep at most 64 KiB each. Temporary upload paths for `save-config` and `apply-lists` must use `/tmp/mihowrt-config.*` and `/tmp/mihowrt-policy-list.*` respectively.

`update-subscription [url]` saves a new URL only after a successful download and validation. `core-update --file` accepts an architecture-compatible local gzip or executable, skips the release digest check with a warning, then uses the normal version/config test and atomic replacement. Verify local files yourself. Online update checks the GitHub release digest when available; API fallback via the latest-release redirect has no digest and logs a warning. Download stalls are bounded (below 2048 bytes/s for 60 s, two retries), not a fixed five-minute total.

`mihowrt uninstall` stops the service, removes policy/runtime state, core, dashboard and geodata; configs stay. It does **not** remove the package: use the installer, `apk del` or `opkg remove` (see [README](../README.md#remove)).


## Files

| Path | Purpose |
|---|---|
| `/etc/config/mihowrt` | Settings (UCI) |
| `/etc/mihowrt/api_secret` | Mihomo controller secret (root-only, mode 600) |
| `/opt/clash/config.yaml` | Your Mihomo YAML (backup: `config.yaml.bak`) |
| `/opt/clash/lst/*.txt` | Policy lists (`direct_src.txt`: devices always direct) |
| `/opt/clash/bin/clash` | Mihomo core |
| `/etc/mihowrt/` | HWID, subscription metadata, remote list cache, saved proxy selection |
| `/opt/clash/ui/` | Optional dashboard on flash |
| `/tmp/clash/` | Runtime rulesets, providers, cache.db and controller socket |
| `/var/run/mihowrt/` | Health, job state, locks, network fingerprint and config test stamp (tmpfs) |
| `/tmp/mihowrt/config.yaml` | Generated runtime config (`.profile`: mode and provider settings) |

## Known limits

- **Dumb AP mode:** if the default route is via the LAN bridge, MihoWRT treats that bridge as WAN and does not exclude its non-RFC1918 connected subnets. This follows the connected-network algorithm; do not assume AP mode has the same exclusions as routed LAN mode.
- **RAM:** 128 MiB is for small YAML. Large configs (several MiB) need 256 MiB+; an 8 MiB fixture OOMed on 128 MiB in all tested builds, including 0.10. The 8 MiB upload limit is not a capacity guarantee. 512 MiB passed; 256 MiB has not been measured. Core updates succeeded on 128 MiB in the VM with only about 6–8 MiB MemAvailable at the low point; this is not a physical-router guarantee.

- The read-only LuCI access (`mihowrt-read`) exposes the Mihomo YAML (which holds
  provider credentials), the YAML passed to Mihomo (*Show the YAML passed to
  Mihomo*, controller secret hidden) and the subscription link to every LuCI
  user with read access. Give such access only to people you trust with them.
- Connected-network exclusions read only the main routing table, not mwan3 or
  other policy tables. Public VPN routes without `via` with prefixes at least
  /16 (IPv4) or /32 (IPv6) are treated as local and go direct through the tunnel.
- IPv6 fake-IP is not used. IPv6 destinations are handled by the lists and by
  the *All traffic* mode.
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

The stock 24.10.8 image has BusyBox `ip`, not iproute2 (`ip-tiny`/`ip-full`); image/feed inspection alone does not prove all runtime parsing or routing behaviour. The 24.10 VM acceptance is still pending; no parity claim follows from package availability alone.
<!-- 24.10 limits: pending VM -->
