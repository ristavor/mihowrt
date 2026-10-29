# Changelog

## 0.11.0

Added
- OpenWrt 24.10 packages (`.ipk`, opkg) alongside OpenWrt 25.12 APKs; the installer selects the package manager. Both formats and the Russian translation are published with checksums.
- Optional dashboard: fresh installs no longer download it automatically. Install it on Overview while MihoWRT is running, open it after installation, or remove it under Traffic → Advanced. Existing dashboard installations are retained.
- Local Mihomo core installation with `mihowrt core-update --file <path.gz|binary>`, plus a configurable installer release asset base (`MIHOWRT_RELEASE_URL`) and offline installation instructions.
- Diagnostics show runtime data size/free tmpfs and whether the client IPv6 block is in effect in the current mode.
- Provider-controlled blocking of client IPv6 that would bypass Mihomo, with local IPv6 and router/Mihomo traffic preserved. It is off by default, works only in *Only selected traffic via proxy* mode, and can be set by the provider (`x-mihowrt.block-client-ipv6`) or switched on the *Traffic* page (*Use my own value*).
- *Devices always direct* now also works in *All traffic via proxy* with fake-IP DNS: connections of those devices to fake addresses go through a dedicated Mihomo listener (`mihowrt-direct`, port 7895) and are sent DIRECT. If the provider YAML cannot be extended safely (for example non-empty flow-style `listeners` or `rules`), the subscription still applies, a warning is logged and the devices follow the normal policy, as in 0.10.
- Diagnostics warn about a plain-http subscription link and report proxy listeners that are open without a password, including the ones defined under `listeners:`.
- Dependencies replaced `jq` with `ucode` (`mihowrt-json`) and added `cgi-io` for streaming backend JSON without extra fork/memory overhead.
- Mihomo log level ownership (R4): managed via UCI `mihomo_log_level` (default `error` to prevent syslog/logd saturation from connection-level logging; the web dashboard continues streaming all levels).
- Guest and isolated zones with fw4 `input REJECT` are admitted for redirected DNS and TPROXY via fw4 include `/usr/share/nftables.d/chain-pre/input/30-mihowrt.nft` (R3).

Fixes
- Replies to inbound connections (port forwards and router WAN services) are no longer intercepted. Routing rules use priorities 50–99 ahead of typical NetBird/mwan3 rules, and reject overlapping NetBird marks. Kernel-disabled IPv6 permits IPv4-only startup.
- Failed subscription policy applies restore the previous YAML, runtime config and profile; the older backup is retained until success. Persistent list caches and subscription metadata are published atomically even across filesystems.
- DNS and `x-mihowrt` block forms are checked consistently, including quoted/spaced keys. Empty port scopes are rejected. A partial remote-list update now reports failure while retaining old caches for failed downloads.
- Remote-list caches are capped at 8 MiB total and background output/error logs at 64 KiB each. Remote-list check stamps and crontab comparisons avoid unnecessary flash writes; idle cron ticks skip list work.
- Automatic subscription/list updates share the LuCI job slot. Start clears stale health/errors, hotplug retains startup events, and routing failures are no longer described as core-readiness failures.
- Background jobs keep unsaved page edits. Saving a changed subscription link validates it through a download before storing it; list refresh is always accessible, proxy selection is debounced, and Overview refreshes once after startup. Read-only users no longer see write actions; errors and Russian translations are clearer.
- The installer works without a controlling terminal when an action is supplied, installs only missing dependencies, preserves autostart on update and reports reinstall/removal accurately. Default HTTPS downloads cannot redirect to another protocol; the fallback script mirror is release-pinned.
- Package upgrades/reinstalls clean unmerged APK UCI defaults; removal does not create empty config directories.
- Stopping the service removes its IPv6 local route also with BusyBox `ip`; before, every stop left a routing table in use, and after about 50 restarts the service could not start ("No free routing table id").
- Router-owned DNS (queries sent to any address of the router, including a global IPv6 address) always reaches dnsmasq, so local names such as `<host>.lan` keep resolving to local addresses.
- The controller secret is no longer stored in UCI or passed on command lines: it lives in `/etc/mihowrt/api_secret` (root-only) and is hidden in the read-only YAML view. An upgrade moves the old value there.
- *Last update* of the subscription survives a reboot.
- *Update now* with an empty subscription link is refused instead of downloading with the old link.
- Lists with port-scoped entries (`;443`) produce one nftables rule per port spec instead of one per entry, and only the lists of the active mode are resolved.
- Bursts of interface events (hotplug) are merged into one network refresh.
- Reloading unchanged generator inputs reuses the runtime YAML and skips its core test; unchanged policy inputs skip list resolution/ruleset rendering. Network refreshes also skip unchanged connected-prefix/DNS inputs. The proxy group list is built in linear time.
- Provider list URLs that point to local or reserved ranges (including `198.18.0.0/15`, `192.0.0.0/24`, multicast and `fec0::/10`) are rejected; `192.88.99.0/24` is treated as local.
- Cached lists are kept when the provider profile cannot be read.
- Core downloads use stall limits and retries instead of a fixed five-minute deadline; compressed downloads and test files are cleaned up earlier. Installed-core validation uses the running-core memory budget, while candidate-core validation keeps a smaller budget. Core updates worked in the 128 MiB VM with ≈6–8 MiB minimum MemAvailable; large YAML still needs more RAM.
- The YAML renderer streams the source instead of storing the whole output; list resolution classifies entries in one pass, light status/job reads load fewer modules, and diagnostics read the package database once. These reduce transient work without adding a resident process.
- Sysupgrade backup trims unneeded cache files to avoid backup bloat (R26): only `/etc/mihowrt/api_secret`, `/etc/mihowrt/hwid`, and `/etc/mihowrt/subscription.json` are retained. Lists re-download on first update after sysupgrade, and proxy-group selections stored in `cache.db` reset after sysupgrade.
- Default provider cache directories `/opt/clash/proxies` and `/opt/clash/rules` are linked to tmpfs to eliminate flash wear on scheduled updates (R11); user-authored `type: file` providers must not live there.
- Named routing tables in `/etc/iproute2/rt_tables` are reserved by the table allocator, and routing policy rules are added idempotently without failing on existing rules (R12).
- Packaged entrypoints are hardened against environment seam overrides (`MIHOWRT_BACKEND`, `MIHOWRT_LIB_DIR`, etc.) via build-time variable binding and environment unsetting (R10).

Project
- User-focused English and Russian quick starts; separate user guide, technical reference and development/release instructions, including low-memory and dumb-AP limits.
- Release CI builds both SDKs, inspects APK/IPK contents, supports build-only manual runs, and limits job time/concurrency. Bug reports request diagnostics, OpenWrt version and architecture; each new release candidate needs a new package revision.
- The boot-time `mihowrt-recover` script is removed (a reboot already clears its state); an upgrade removes its leftover link.
- Internal cleanups: one helper for locked configuration changes, one `yaml_has_top_key`, one curl call in `http_fetch`, no dead helpers.
- `tools/build-sdk.sh` builds only in Docker; GitHub Actions are pinned to commit SHAs.
- New tests: more coverage of deferred gaps and a repeatable VM network acceptance (`tests/router/run-network.sh`) that covers client IPv6, local names, fake-IP direct devices, NetBird-style marks, routes and DNS.

## 0.10.2

Changes
- Removed the 0.10.1 font rule for read-only values: it had no effect. Their font comes from the theme (footstrap shows all field values in monospace on purpose, stock LuCI pages too).

## 0.10.1

Fixes
- *Traffic mode* shows "unknown" when the YAML profile cannot be read, instead of claiming "Only selected traffic via proxy"; lists are then no longer marked as used in the other mode.
- Read-only values (such as the traffic mode) use the page font instead of a monospace one in some browsers.

## 0.10.0

Fixes
- Long actions (connect, core and subscription update, list refresh, saving the YAML, start/stop/restart) no longer fail with a timeout or get killed halfway: they run in the background, one at a time, and the page waits for the result.
- The YAML editor and lists handle files up to 8 MiB and 1 MiB instead of failing on large ones; the editor shows a clear error when the YAML cannot be loaded instead of an empty field.
- An empty YAML can no longer replace a working configuration.
- *Restore the previous YAML* brings back the last configuration (and can be undone).
- A failed reload of the configuration restores the previous one instead of leaving a broken one.
- Networks connected to the router (LAN, guest, IoT, delegated IPv6 prefixes) are never sent through the proxy, and no longer bypass the firewall zones.
- The status shows the real service state (running, starting, DNS not answering, stopped after an error) and updates by itself.
- Diagnostics warn about conflicting proxy packages, little free flash or RAM, and proxy ports open without a password.
- Devices can be added by MAC address, which covers IPv4 and IPv6 together; the lists show devices that are not connected now.
- Remote lists up to 1 MiB are supported, unused cached lists are cleaned up, and provider list URLs must be public https addresses.
- Settings with leading zeros (for example `08`) no longer break the service.
- A killed process can no longer leave the router stuck on "Runtime is busy".
- Leftover temporary files of failed core and subscription downloads are removed.
- A failed settings migration during an upgrade no longer leaves the service stopped.
- A new install refreshes remote lists every 24 hours (existing installs keep their value).
- Removing the package now also removes the Mihomo core, the dashboard, geodata and leftovers; your YAML, lists, settings and device ID are kept.
- The installer checks every downloaded APK against `SHA256SUMS` and no longer depends on the GitHub API.
- Traffic page: a single *Save & Apply* button applies lists and settings together.
- `mihowrt dns-refresh` is now `net-refresh`; update scripts that call the old name.
- The proxy group delay test times out after 15 seconds.
- All MihoWRT pages: error messages for timeouts and expired sessions are clear and translated.
- Updating the Mihomo core works on routers with little free flash: the check uses the download size, and a full flash stops the update and keeps the current core.
- An upgrade from 0.9 stops the old service quickly instead of waiting about a minute.
- A background job that failed while the page was reloading or closed shows its error on the next page load.
- Subscription page: *Show the YAML passed to Mihomo* shows the generated configuration read-only; the YAML editor loads when opened.
- Traffic page: the lease picker has no duplicate labels, devices with a private Wi-Fi MAC are marked in it, and the advice for them is part of the field description (no layout jumps).
- Upgrades are supported from 0.9.0 and newer; from 0.8 or older remove MihoWRT first, then install.

Project
- CI runs the test suite on every push and pull request.
- Tagged releases (`vX.Y.Z`) build the APKs and publish them with `SHA256SUMS`.
- The package is licensed GPL-3.0-or-later (`LICENSE`).
