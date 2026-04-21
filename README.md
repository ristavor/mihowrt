# MihoWRT

LuCI package and policy layer for running Mihomo on OpenWrt APK systems.

Project adds:
- LuCI pages for service control, policy settings, and `config.yaml` editing
- direct-first traffic policy based on `nftables`, `ip rule`, and `dnsmasq`
- runtime data placement in tmpfs to reduce flash writes
- crash recovery for `dnsmasq` state and runtime snapshot
- installer-managed Mihomo core install and update

## Quick Install

Run on router:

```sh
wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

or:

```sh
curl -fsSL https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

Behavior:
- script menu:
  - `1. Install/update package + kernel`
  - `2. Install/update kernel only`
  - `3. Remove package + kernel`
  - `4. Stop`
- for non-interactive package install/update:

```sh
MIHOWRT_ACTION=package wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

- other non-interactive modes:

```sh
MIHOWRT_ACTION=kernel wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
MIHOWRT_ACTION=remove wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
MIHOWRT_ACTION=stop wget -O - https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
```

## How It Works

1. Mihomo user config lives in `/opt/clash/config.yaml`.
2. Service starts Mihomo with `/opt/clash` as working directory.
3. Policy layer reads required runtime values from `config.yaml`.
4. Runtime layer applies:
   - `nftables` rules for interception
   - `ip route` and `ip rule` for marked traffic
   - `dnsmasq` redirection to Mihomo DNS
5. Large and write-heavy runtime data is moved to `/tmp/clash`.

## Repository Layout

```text
rootfs/etc/config/mihowrt
  UCI settings for package behavior

rootfs/etc/init.d/
  Service scripts for main runtime and boot recovery

rootfs/usr/bin/mihowrt
  Main orchestration entrypoint

rootfs/usr/lib/mihowrt/
  Shell modules for helpers, runtime, DNS, nftables, and policy

rootfs/www/luci-static/resources/view/mihowrt/
  LuCI pages

rootfs/www/luci-static/resources/mihowrt/
  Shared LuCI helpers

rootfs/opt/clash/config.yaml
  Default Mihomo config template

rootfs/opt/clash/lst/
  Policy lists for always-proxy destination and source entries
```

## Main Files

- `/opt/clash/config.yaml`: main Mihomo config
- `/opt/clash/lst/always_proxy_dst.txt`: destination IP/CIDR list forced through proxy
- `/opt/clash/lst/always_proxy_src.txt`: source IP/CIDR list forced through proxy
- `/etc/config/mihowrt`: package flags such as enable state, DNS hijack, QUIC handling

## Runtime Paths

- `/opt/clash/bin/clash`: Mihomo core binary
- `/tmp/clash/ruleset`: ruleset cache
- `/tmp/clash/proxy_providers`: provider cache
- `/tmp/clash/cache.db`: Mihomo cache database
- `/etc/mihowrt/dns.backup`: persistent DNS backup for crash recovery
- `/var/run/mihowrt/runtime.snapshot.json`: active runtime snapshot used for safe reload and diagnostics
- `/var/run/mihowrt/always_proxy_dst.snapshot`: active destination list snapshot
- `/var/run/mihowrt/always_proxy_src.snapshot`: active source list snapshot
- `/tmp/mihowrt` and `/var/run/mihowrt`: transient runtime state

## Commands

Main helper:

```sh
/usr/bin/mihowrt prepare
/usr/bin/mihowrt cleanup
/usr/bin/mihowrt recover
/usr/bin/mihowrt reload
/usr/bin/mihowrt validate
/usr/bin/mihowrt status
/usr/bin/mihowrt status-json
/usr/bin/mihowrt logs-json
/usr/bin/mihowrt read-config
/usr/bin/mihowrt apply-config /tmp/candidate.yaml
/usr/bin/mihowrt init-layout
```

Service control:

```sh
/etc/init.d/mihowrt start
/etc/init.d/mihowrt stop
/etc/init.d/mihowrt restart
/etc/init.d/mihowrt reload
```

## Notes

- `config.yaml` is source of truth for runtime values used by policy layer
- package expects `nftables`, `jq`, and `kmod-nft-tproxy`
- installer uses `wget` or `curl` to fetch package and Mihomo core releases
- package builds as `PKGARCH:=all` / `arch: noarch`, so `.apk` itself is architecture-independent inside same OpenWrt release line
- bundled UI is not stored in repo; Mihomo downloads UI from `external-ui-url`
- config files under `/opt/clash` and `/etc/config` are protected as conffiles
- installer preserves existing `config.yaml`, policy list files, and explicit user deletions of default list files across package reinstall/update

## Known Limits

- full atomic reload for `nft + route rule + dnsmasq` is not implemented yet
- installer kernel update still downloads latest release from GitHub without pinned checksum
