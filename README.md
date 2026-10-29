# MihoWRT

[Русский](README.ru.md)

MihoWRT runs [Mihomo](https://github.com/MetaCubeX/mihomo) on OpenWrt with a LuCI interface: transparent IPv4/IPv6 proxying (TPROXY), DNS redirection, subscriptions, device/address lists and self-healing. Mihomo keeps control of proxy groups, rules, providers and DNS. Paste a subscription link to begin; advanced users can edit the YAML.

## Requirements

- OpenWrt **25.12 (apk)** or **24.10 (opkg)**, firewall4/nftables. See [24.10 limits](docs/reference.md#openwrt-2410).
- **128 MiB RAM minimum, 256 MiB recommended.** Keep the YAML small on 128–256 MiB. An 8 MiB config ran out of memory on 128 MiB in every tested build, including 0.10, and on 256 MiB; it passed on 512 MiB. Sizes between were not measured.
- **100 MiB+ free flash is a safe budget**: core ≈20 MB compressed, up to ≈55 MB unpacked, ×2 during update; geodata and dashboard are extra (dashboard measured 5284 KiB installed). Sizes vary by core/architecture; compressing overlays (UBIFS/JFFS2) need less space. The installer checks for 2 MiB free; core update checks free space ≥ compressed file size + 4 MiB and keeps the old core if unpacking fills flash.
- Core updates worked on 128 MiB in the VM, with only ≈6–8 MiB MemAvailable at the low point; not a hardware guarantee.
- Dependencies: `luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl` (package manager resolves them). Russian UI also needs `luci-i18n-base-ru` and `luci-i18n-mihowrt-ru`.

## Install and first start

1. Run on the router as root (`wget` is on standard OpenWrt images; the installer adds `curl` if missing):
   ```sh
   wget -qO- https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh
   ```
   With curl already installed: `curl -fsSL https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | sh`. Choose install and language. The installer selects APK/IPK, checks `SHA256SUMS`, installs missing dependencies and runs `core-update` **only if the core is missing**. For Russian, install the base translation too: `apk add luci-i18n-base-ru` or `opkg update && opkg install luci-i18n-base-ru`.
2. Open **LuCI → Services → MihoWRT**, paste the subscription link and press **Connect**.
3. Check Overview; use **Traffic** for devices and exclusions, **Diagnostics** if something fails. The optional dashboard is off by default: **Install dashboard** on Overview is available only while the service runs; remove it under **Traffic → Advanced**.

To keep a local installer, download it and run with explicit action/language; the piped form also works without a terminal:

```sh
wget -O install.sh https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh
MIHOWRT_ACTION=install MIHOWRT_LANGUAGE=en sh install.sh
wget -qO- https://raw.githubusercontent.com/ristavor/mihowrt/main/install.sh | MIHOWRT_ACTION=install MIHOWRT_LANGUAGE=en sh
```

## Update

Run the installer again. APK and IPK updates keep language, core and user files, preserve running/stopped state, and restart a previously running service; a disabled service is not enabled again. Update Mihomo separately on Overview or with `mihowrt core-update`. Subscription updates replace your YAML, including manual edits. Upgrades from 0.9.0+ are supported; from 0.8 or older remove the package first, then install.

## Remove

Use `MIHOWRT_ACTION=remove sh install.sh`, or the commands for your package manager (omit the translation package if not installed):

```sh
apk del luci-i18n-mihowrt-ru luci-app-mihowrt
# OpenWrt 24.10:
opkg remove luci-i18n-mihowrt-ru luci-app-mihowrt
```

APK and IPK removal stops the service and clears DNS/nftables/routes, the cron entry, core, dashboard, geodata, subscription metadata (`subscription.json`), saved proxy selection (`cache.db`) and remote-list cache (`policy-cache`). YAML and `config.yaml.bak`, lists, UCI settings and `/etc/mihowrt/hwid` stay, so the provider sees the same device after reinstall. **`mihowrt uninstall` performs that cleanup but does not remove the package.**

## If GitHub is unavailable

If only `raw.githubusercontent.com` is blocked, the release-pinned installer mirror may help:

```sh
wget -qO- https://cdn.jsdelivr.net/gh/ristavor/mihowrt@v0.11.0/install.sh | sh
```

This third-party mirror is an extra trust point: its script runs as root. It does not mirror the package/core downloads. Use an HTTPS mirror you trust: it must contain `SHA256SUMS`, `luci-app-mihowrt.apk` (25.12) / `luci-app-mihowrt.ipk` (24.10) and, for Russian, `luci-i18n-mihowrt-ru.apk` / `luci-i18n-mihowrt-ru.ipk`. The installer downloads these **fixed names**, not versioned filenames; plain HTTP cannot protect the checksum file from tampering:

```sh
MIHOWRT_ACTION=install MIHOWRT_RELEASE_URL=https://mirror.example/mihowrt/v0.11.0 sh install.sh
```

RC testers can use `MIHOWRT_RELEASE_URL=https://github.com/ristavor/mihowrt/releases/download/v0.11.0-rc1` (replace the rc number as needed). The override affects MihoWRT packages only, not Mihomo core downloads. For a manual transfer, on a PC download the matching `.apk` (25.12) or `.ipk` (24.10), optional Russian package and `SHA256SUMS` from a [MihoWRT release](https://github.com/ristavor/mihowrt/releases), plus the Linux core `.gz` for the **router's CPU architecture** (`DISTRIB_ARCH` in `/etc/openwrt_release`; [asset mapping](docs/reference.md#core-asset-selection)) from [Mihomo releases](https://github.com/MetaCubeX/mihomo/releases). Keep the downloaded package filenames unchanged. On the PC, check only the needed lines of `SHA256SUMS` (use `.ipk` for 24.10; include the translation's line too if downloaded), and check the core's published digest separately:

```sh
awk '$2 == "luci-app-mihowrt.apk" { print }' SHA256SUMS | sha256sum -c -
# For Russian, also:
awk '$2 == "luci-i18n-mihowrt-ru.apk" { print }' SHA256SUMS | sha256sum -c -
```

Transfer with `scp -O`: stock Dropbear has no SFTP server, so use the legacy SCP protocol. Replace `router` with your router's SSH host:

```sh
scp -O ./luci-app-mihowrt.apk ./mihomo.gz root@router:/tmp/
# Use ./luci-app-mihowrt.ipk instead on 24.10; transfer the Russian package too if wanted.
```

On the router, install dependencies from OpenWrt feeds, then the transferred files (choose one package manager):

```sh
cd /tmp
apk update && apk add luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl
apk add --allow-untrusted ./luci-app-mihowrt.apk
# OpenWrt 24.10 instead:
opkg update && opkg install luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl
opkg install ./luci-app-mihowrt.ipk
mihowrt core-update --file /tmp/mihomo.gz
/etc/init.d/mihowrt enable
# Remove only your transferred files; --file leaves the source in tmpfs:
rm /tmp/mihomo.gz /tmp/luci-app-mihowrt.apk  # use .ipk on 24.10
```

For Russian, also run `apk add luci-i18n-base-ru` and `apk add --allow-untrusted ./luci-i18n-mihowrt-ru.apk`, or `opkg install luci-i18n-base-ru ./luci-i18n-mihowrt-ru.ipk`; remove that transferred file afterwards. Then follow steps 2–3 above. With no feed access, also bring all missing architecture/kernel-matched dependencies from the OpenWrt feeds. Local core installation skips the release digest check (logged), but still tests the core before replacing it. Packages are not signed; `SHA256SUMS` detects corruption, not a compromised release.

## If internet is lost

1. Open LuCI at your router address (usually `http://192.168.1.1`) — LuCI works without an internet connection.
2. Go to **Services → MihoWRT → Overview** and press **Stop** (or run `service mihowrt stop` over SSH).
3. Stopping removes MihoWRT DNS redirection and routing rules, restoring direct internet access.
4. If internet returns, check **Diagnostics** or read the journal with `logread -e mihowrt` (or in LuCI: **Status → System Log**).
5. "Stop" lasts until reboot. To prevent MihoWRT from starting on boot, run `service mihowrt disable` over SSH.

## FAQ

- **Where is the mode switch?** There is none: the YAML DNS settings select *Only selected traffic via proxy* or *All traffic via proxy except exclusions*. See [modes](docs/user-guide.md#modes).
- **Do I need the dashboard?** No. MihoWRT works without it; installing it uses flash and restarts the service.
- **Does Stop restore normal networking?** Yes, it removes MihoWRT DNS/routing policy. The watchdog also fails open after repeated DNS failures; this is not a kill-switch.
- **Can I keep my YAML?** Yes. MihoWRT generates a separate runtime file; subscription updates replace the saved original. The editor can restore the previous YAML.

## Documentation

[User guide](docs/user-guide.md) · [Technical reference / CLI / limits](docs/reference.md) · [Development](docs/development.md) · [Open issues](docs/open-issues.md) · [Changelog](CHANGELOG.md)

GPL-3.0-or-later; see [LICENSE](LICENSE).
