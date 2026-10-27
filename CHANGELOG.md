# Changelog

## 0.11.0

Added
- Provider-controlled blocking of client IPv6 that would bypass Mihomo, with local IPv6 and router/Mihomo traffic preserved. It is off by default, works only in *Only selected traffic via proxy* mode, and can be set by the provider (`x-mihowrt.block-client-ipv6`) or switched on the *Traffic* page (*Use my own value*).
- *Devices always direct* now also works in *All traffic via proxy* with fake-IP DNS: connections of those devices to fake addresses go through a dedicated Mihomo listener (`mihowrt-direct`, port 7895) and are sent DIRECT. If the provider YAML cannot be extended safely (for example non-empty flow-style `listeners` or `rules`), the subscription still applies, a warning is logged and the devices follow the normal policy, as in 0.10.
- Diagnostics warn about a plain-http subscription link and report proxy listeners that are open without a password, including the ones defined under `listeners:`.

Fixes
- Router-owned DNS (queries sent to any address of the router, including a global IPv6 address) always reaches dnsmasq, so local names such as `<host>.lan` keep resolving to local addresses.
- The controller secret is no longer stored in UCI or passed on command lines: it lives in `/etc/mihowrt/api_secret` (root-only) and is hidden in the read-only YAML view. An upgrade moves the old value there.
- *Last update* of the subscription survives a reboot.
- *Update now* with an empty subscription link is refused instead of downloading with the old link.
- Lists with port-scoped entries (`;443`) produce one nftables rule per port spec instead of one per entry, and only the lists of the active mode are resolved.
- Bursts of interface events (hotplug) are merged into one network refresh.
- Reloading an unchanged configuration skips the core test; the proxy group list is built in linear time.
- Provider list URLs that point to local or reserved ranges (including `198.18.0.0/15`, `192.0.0.0/24`, multicast and `fec0::/10`) are rejected; `192.88.99.0/24` is treated as local.
- Cached lists are kept when the provider profile cannot be read.
- The test run of a downloaded Mihomo core is memory-limited, which gives more free RAM during a core update on 128 MiB routers (the lowest free memory seen in the VM rose from about 4.3–4.8 MiB to about 6.0 MiB; no out-of-memory kill in either case).

Project
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
