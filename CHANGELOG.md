# Changelog

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

Project
- CI runs the test suite on every push and pull request.
- Tagged releases (`vX.Y.Z`) build the APKs and publish them with `SHA256SUMS`.
- The package is licensed GPL-3.0-or-later (`LICENSE`).
