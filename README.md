# MihoWRT

MihoWRT runs [Mihomo](https://github.com/MetaCubeX/mihomo) on an OpenWrt router
and gives it a simple LuCI interface. Mihomo stays the proxy engine (rules,
groups, providers, DNS); MihoWRT connects it to the router: transparent proxy
(TPROXY) for IPv4 and IPv6, DNS redirection, policy lists, subscriptions,
updates and self-healing.

Typical use:

- **Most users** paste a subscription link and press *Connect*. The
  subscription decides the mode, DNS and router settings (provider-first);
  every provider setting can be overridden on the router.
- **Advanced users** edit the Mihomo YAML on the *Subscription* page.
- Everyone can keep addresses or devices always via proxy or always direct on the *Traffic* page.

## Requirements

- OpenWrt 25.12 or newer (APK package manager), fw4/nftables.
- About 80 MiB of free flash for the Mihomo core (about 60 MiB unpacked) and
  128 MiB of RAM or more.
- Dependencies installed automatically: `luci-base nftables jq kmod-nft-tproxy curl`.

## Install, update, remove

On the router:

```sh
curl -fsSL https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

If `raw.githubusercontent.com` is unreachable, use the jsDelivr mirror of the
same file:

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/ristavor/mihowrt@main/install.sh | sh
```

Release downloads (installer and `mihowrt core-update`) use the GitHub API
first; if it is blocked or rate-limited, the latest tag is taken from the
`github.com/<repo>/releases/latest` redirect and files are downloaded from
`github.com/<repo>/releases/download/<tag>/`. Only on the API path is the
SHA-256 published by GitHub checked.

The installer asks for the action (install/update or remove) and, on a fresh
install, for the language (English or Russian). Updates keep the language.
Non-interactive use:

```sh
MIHOWRT_ACTION=install MIHOWRT_LANGUAGE=ru sh install.sh
MIHOWRT_ACTION=remove sh install.sh
```

After a fresh install open **LuCI → Services → MihoWRT** and connect your
subscription. Package updates through `apk` keep the service running: the old
service is stopped, settings are migrated and the new version starts again.

## Pages

| Page | What it does |
|---|---|
| Overview | First-run *Connect a subscription* card, status, traffic and expiry, proxy group selection with latency test, start/stop, dashboard, core update |
| Subscription | Subscription link and *Update automatically*; *Advanced* holds the YAML editor (*Check and apply*) |
| Traffic | Mode (read-only), lists of the active mode, devices from DHCP leases, provider settings with *Use my own value*; *Advanced* holds interfaces, DNS redirect, QUIC block, NTP and subscription DNS bypass, NetBird |
| Diagnostics | Checklist with fixes (core, config, service, DNS answers, rules, conflicting dnsmasq servers), details and log |

### Modes

The mode follows the DNS settings of your YAML; there is no switch:

- **Only selected traffic via proxy**: only when `dns.enhanced-mode` is
  `fake-ip` and `dns.fake-ip-filter-mode` is `whitelist`. Addresses and
  devices from the lists, plus domains that Mihomo answers with a fake-IP
  (usually the blocked sites of your subscription), go to Mihomo. Everything
  else is direct.
- **All traffic via proxy except exclusions**: every other case (blacklist or
  rule filter, `redir-host`, `normal`, no `dns` section). All TCP/UDP goes to
  Mihomo, except *Addresses always direct* and *Devices always direct*.
  *Devices always direct* needs DNS mode `redir-host` or `normal`: with
  fake-IP their domains would resolve to addresses only Mihomo can reach.

In both modes Mihomo's own rules decide the outbound (proxy group or DIRECT).

**Upgrade note (0.9.0):** subscriptions without a fake-IP whitelist now run in
*All traffic via proxy* mode. The UCI option `policy_mode` is removed.

### Provider settings (`x-mihowrt`)

A provider (or you, in the YAML) can set router options in a top-level
`x-mihowrt` section. It is removed from the config Mihomo gets:

```yaml
x-mihowrt:
  disable-quic: true            # Block QUIC for proxied traffic
  dns-hijack: true              # Redirect client DNS to Mihomo
  bypass-ntp: true              # Time sync without Mihomo
  bypass-subscription-dns: true # Subscription server without Mihomo
  lists-interval: 24            # remote list refresh, hours (0-8760)
  proxy-ips:                    # "Only selected" mode: always via Mihomo
    - https://provider.example/telegram.txt
    - 91.108.4.0/22
  direct-ips:                   # "All traffic" mode: bypass Mihomo
    - https://provider.example/ru.txt
```

Booleans: `true/false/yes/no/on/off/1/0`. Block style only; an invalid or
unknown key is ignored with a warning in the log and never rejects the
subscription. Without a key the router setting applies. NetBird, client
interfaces, device lists and the update period are never provider-controlled.

On the *Traffic* page a provider value is shown read-only with *Set by your
provider*; *Use my own value* switches that one setting to your value (UCI
`list provider_override`), even when the provider later drops or re-adds the
key. A provider list offers *Provider list* (default), *Provider list + mine*
and *Only mine* (UCI `dst_list_source` / `direct_list_source`). Your list file
is never deleted; with *Provider list* the page says how many of your entries
are not applied. Provider values are kept in tmpfs
(`/tmp/mihowrt/config.yaml.profile`), never in UCI or flash.

### Lists

One entry per line, IPv4 or IPv6:

```text
1.1.1.1
8.8.8.0/24
2001:db8::/32
9.9.9.9;443          # only these ports
;53                  # any address, these ports
https://example.com/list.txt;443   # remote list, cached on flash
# comment
```

Remote lists are refreshed every *Update remote lists every (hours)* or with the
button. Applying policy never waits for the network: it uses the cache.
Provider list entries are validated the same way; invalid ones are dropped
with a warning.

## How it works

### Router-owned Mihomo settings

Your YAML (`/opt/clash/config.yaml`) is never rewritten. At start MihoWRT
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
secret: "<generated, stored in UCI>"
external-ui: ui          # dashboard (zashboard), owned by the router
external-ui-url: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip"
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
style (`dns: {…}`, `x-mihowrt: {…}`) is rejected with an error. Every change is validated with `mihomo -t` before it is used; Mihomo's
own error message is shown in LuCI. The result is remembered in
`/var/run/mihowrt/config.ok|config.err` for Diagnostics, so status never runs
the core.

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
- **Boot:** `mihowrt-recover` clears leftovers even when autostart is off.
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
  providers are loaded (usually well under a second).

### nftables and routing

Table `inet mihowrt` marks selected packets with `0x08000000`. Other mark bits
are preserved, so the table coexists with NetBird (`0x1BD00` namespace) and
zapret (`0x40000000`, `0x20000000`). An `ip rule` and `ip -6 rule` send marked
packets to a local table, and TPROXY hands them to Mihomo on
`127.0.0.1:7894` / `[::1]:7894`. Local destinations (`fib daddr type local`),
private ranges, DNS, Mihomo's own traffic (routing mark 2) and, optionally,
NTP are never intercepted. Incoming NetBird traffic is never touched; outbound
NetBird transport is captured only with *Route outbound NetBird through Mihomo*.

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
now*. Remote lists are refreshed when due.

## Command line

```text
mihowrt status-json | logs-json [lines] | subscription-json | proxies-json
mihowrt update-subscription [url] | set-subscription <url> <0|1> | profile-json   # a new [url] is saved only if it downloads and passes the check
mihowrt update-lists | core-update | recover | reload | dashboard-json
/etc/init.d/mihowrt start | stop | restart | reload | enable | disable
```

## Files

| Path | Purpose |
|---|---|
| `/etc/config/mihowrt` | Settings (UCI) |
| `/opt/clash/config.yaml` | Your Mihomo YAML (backup: `config.yaml.bak`) |
| `/opt/clash/lst/*.txt` | Policy lists (`direct_src.txt`: devices always direct) |
| `/opt/clash/bin/clash` | Mihomo core |
| `/etc/mihowrt/` | HWID, subscription metadata, remote list cache, saved proxy selection |
| `/tmp/mihowrt/config.yaml` | Generated runtime config (`.profile`: mode and provider settings) |

## Development

```sh
docker build -t mihowrt-test:local -f Dockerfile.test .
docker run --rm -v "$PWD:/workspace:ro" -w /workspace mihowrt-test:local bash tests/run.sh
./tools/build-sdk.sh build     # APKs into dist/ (OpenWrt 25.12.6 SDK in Docker)
```

On macOS the SDK runs in a Linux container with a named volume
(`mihowrt-sdk-25.12.6`) because APFS is case-insensitive. The package is noarch,
so only `luci-base/host` (`po2lmo`) is compiled.

Release order (the tag must equal `v` + `PKG_VERSION` from `Makefile`):

```sh
git tag vX && git push origin vX   # starts the release workflow
# wait for the release workflow to finish (APKs + SHA256SUMS in the release)
git push origin main
```

The release workflow runs the tests, builds both APKs, and publishes the
versioned and fixed-name APKs with `SHA256SUMS`; the notes come from the
matching `## X` section of `CHANGELOG.md`. APKs are not signed yet.

Real-router checks run in an OpenWrt 25.12.6 x86/64 QEMU VM:

```sh
./tests/router/start.sh
./tests/router/run-smoke.sh --integration --watchdog   # install, start, DNS, nft, stop, watchdog
./tests/router/stop.sh
```

## License

GPL-3.0-or-later, see `LICENSE`.

## Known limits

- Connected-network exclusions read only the main routing table, not mwan3 or
  other policy tables. Public VPN routes without `via` with prefixes at least
  /16 (IPv4) or /32 (IPv6) are treated as local and go direct through the tunnel.
- IPv6 fake-IP is not used. IPv6 destinations are handled by the lists and by
  the *All traffic* mode.
- Clients using DoH/DoT (browser DoH, Android Private DNS) bypass Mihomo DNS,
  so fake-IP based routing does not apply to them.
- The QEMU VM cannot test hardware offloading or real NetBird peers.
- Device headers (HWID, model) are sent only over HTTPS, but curl repeats them
  if the provider redirects to another HTTPS host.
