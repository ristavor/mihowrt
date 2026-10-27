# MihoWRT

[Русский](README.ru.md)

MihoWRT runs [Mihomo](https://github.com/MetaCubeX/mihomo) on OpenWrt with a LuCI interface: transparent IPv4/IPv6 proxying (TPROXY), DNS redirection, subscriptions, device/address lists and self-healing. Mihomo keeps control of proxy groups, rules, providers and DNS. Paste a subscription link to begin; advanced users can edit the YAML.

## Requirements

- OpenWrt **25.12 (apk)** or **24.10 (opkg)**, firewall4/nftables. See [24.10 limits](docs/reference.md#openwrt-2410).
- **128 MiB RAM minimum, 256 MiB recommended.** Large configs (several MiB) need **256 MiB+**; on 128 MiB keep the YAML small. An 8 MiB config ran out of memory on 128 MiB in every tested build, including 0.10; 512 MiB passed, 256 MiB was not measured.
- **100 MiB+ free flash**: core ≈12 MiB compressed, up to ≈55 MiB unpacked, ×2 during update; geodata and dashboard are extra (dashboard measured 5284 KiB installed). Sizes vary by core/architecture.
- Core updates worked on 128 MiB in the VM, with only ≈6–8 MiB MemAvailable at the low point; not a hardware guarantee.
- Dependencies: `luci-base cgi-io jq nftables kmod-nft-tproxy curl` (package manager resolves them). Russian UI also needs `luci-i18n-base-ru` and `luci-i18n-mihowrt-ru`.

## Install and first start

1. Run on the router as root:
   ```sh
   wget -qO- https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
   ```
   Choose install and language. The installer selects APK/IPK, checks `SHA256SUMS`, installs missing dependencies and runs `core-update` **only if the core is missing**. For Russian, install the base translation too: `apk add luci-i18n-base-ru` or `opkg update && opkg install luci-i18n-base-ru`.
2. Open **LuCI → Services → MihoWRT**, paste the subscription link and press **Connect**.
3. Check Overview; use **Traffic** for devices and exclusions, **Diagnostics** if something fails. The optional dashboard is off by default: **Install dashboard** on Overview is available only while the service runs; remove it under **Traffic → Advanced**.

Without a terminal, download `install.sh` first, then run:

```sh
MIHOWRT_ACTION=install MIHOWRT_LANGUAGE=en sh install.sh
```

## Update

Run the installer again. APK and IPK updates keep language, core and user files, preserve running/stopped state, and restart a previously running service; a disabled service is not enabled again. <!-- verify: 24.10 hooks (sr-opkg-vm) --> Update Mihomo separately on Overview or with `mihowrt core-update`. Subscription updates replace your YAML, including manual edits. Upgrades from 0.9.0+ are supported; from 0.8 or older remove the package first, then install.

## Remove

Use `MIHOWRT_ACTION=remove sh install.sh`, or the commands for your package manager (omit the translation package if not installed):

```sh
apk del luci-i18n-mihowrt-ru luci-app-mihowrt
# OpenWrt 24.10:
opkg remove luci-i18n-mihowrt-ru luci-app-mihowrt
```

APK and IPK removal stops the service and removes the core, dashboard and geodata. YAML, lists, UCI settings and device ID stay. <!-- verify: 24.10 hooks (sr-opkg-vm) --> **`mihowrt uninstall` only cleans up the runtime/core/geodata; it does not remove the package.**

## If GitHub is unavailable

If only `raw.githubusercontent.com` is blocked, the release-pinned installer mirror may help:

```sh
wget -qO- https://cdn.jsdelivr.net/gh/ristavor/mihowrt@v0.11.0/install.sh | sh
```

This third-party mirror is an extra trust point: its script runs as root. It does not mirror the package/core downloads. The installer accepts a trusted release asset base containing packages and `SHA256SUMS`:

```sh
MIHOWRT_ACTION=install MIHOWRT_RELEASE_URL=https://mirror.example/mihowrt/v0.11.0 sh install.sh
```

That override affects MihoWRT packages only, not Mihomo core downloads. For a manual transfer, on a PC download the matching `.apk` (25.12) or `.ipk` (24.10), optional Russian package and `SHA256SUMS` from a [MihoWRT release](https://github.com/ristavor/mihowrt/releases), plus the Linux core `.gz` for the **router's CPU architecture** from [Mihomo releases](https://github.com/MetaCubeX/mihomo/releases). Check package checksums and the core's published digest on the PC. Transfer with `scp` (replace `router` with your router's SSH host):

```sh
scp ./file.apk ./mihomo.gz root@router:/tmp/
# Use ./file.ipk instead on 24.10; transfer the Russian package too if wanted.
```

On the router, install dependencies from OpenWrt feeds first if needed, then:

```sh
cd /tmp
apk add --allow-untrusted ./file.apk
# OpenWrt 24.10 instead:
opkg install ./file.ipk
mihowrt core-update --file /tmp/mihomo.gz
/etc/init.d/mihowrt enable
```

Install the optional translation package the same way, then follow steps 2–3 above. With no feed access, also bring all missing architecture/kernel-matched dependencies from the OpenWrt feeds. Local core installation skips the release digest check (logged), but still tests the core before replacing it. Packages are not signed; `SHA256SUMS` detects corruption, not a compromised release.

## FAQ

- **Where is the mode switch?** There is none: the YAML DNS settings select *Only selected traffic via proxy* or *All traffic via proxy except exclusions*. See [modes](docs/user-guide.md#modes).
- **Do I need the dashboard?** No. MihoWRT works without it; installing it uses flash and restarts the service.
- **Does Stop restore normal networking?** Yes, it removes MihoWRT DNS/routing policy. The watchdog also fails open after repeated DNS failures; this is not a kill-switch.
- **Can I keep my YAML?** Yes. MihoWRT generates a separate runtime file; subscription updates replace the saved original. The editor can restore the previous YAML.

## Documentation

[User guide](docs/user-guide.md) · [Technical reference / CLI / limits](docs/reference.md) · [Development](docs/development.md) · [Open issues](docs/open-issues.md) · [Changelog](CHANGELOG.md)

GPL-3.0-or-later; see [LICENSE](LICENSE).
