# MihoWRT open issues

State after the 0.10.0 work and its beta polish (branch `feat/0.10.0`, 2026-10-23). The release is not tagged or pushed yet.
Each item says where it comes from: a review, VM verification (OpenWrt 25.12.6 x86/64) or the router acceptance run on wr3000s.

## Needs a decision

None.

## Decided 2026-10-23 (0.10.0 beta polish)

1. **Core update on small flash:** the pre-check uses the download size + 4 MiB (UBIFS/JFFS2 store the core compressed); a full flash during unpacking stops the update with `not enough flash` and keeps the current core. Fixed.
2. **Slow stop after an upgrade from 0.9.x:** `wait-stopped` kills a Mihomo that is still alive 5 s after its supervisor is gone (also without a pid file). Fixed.
3. **Redirects of provider list URLs:** documented only (README *Known limits*); no redirect check.
4. **First release run:** `v0.10.0-rc1` as a GitHub pre-release first (`releases/latest` skips it), then `v0.10.0`.
5. **Geodata:** no change; the YAML controls it (`geo-auto-update`, `geox-url`). Mihomo skips writes of identical files, so flash wear is negligible.
6. **Upgrades from 0.8 or older:** not supported any more (pre-0.9 migrations removed); remove MihoWRT, then install.

## Found during 0.10.0 testing and fixed (for the record)

| Where | Problem | Fix |
|---|---|---|
| VM | `cgi-upload` refuses an empty file: clearing a list failed to save | `340a3e51` sends a blank line |
| VM | apk post-upgrade runs `default_postinst` (`init.d start` with the skip marker) before our postinst; procd then stops the running instance and the service stayed stopped | `d5ced47d` preinst marker |
| VM | `apk del` deleted the package-owned `config.yaml` and `lst/*.txt` | `4bfda6f8` prerm `.keep` copies, postrm restore |
| VM browser | the first list-only Save & Apply removed default-valued flags and started a LuCI rollback apply; stray `null` text on Traffic | `d1d2e1ae` |
| Final review | an expired session showed "Lost connection" instead of "Access denied"; `apply-lists` deleted any path given to it | `1f438cfb` |
| Router | notices were lost on the page reload; the first Traffic save after a 0.9.1 upgrade wrote three flags and started a rollback apply | `7e43869b`, `ee05f6b7` |
| Router | core update refused on wr3000s (`need 58 MiB, free 57 MiB`) | beta polish: check from the download size |
| Router | upgrade from 0.9.1 waited ~50 s for an orphaned Mihomo | beta polish: orphan killed 5 s after its supervisor |
| Review | a rejected provider list URL was checked and logged on every list read | beta polish: filtered once per config build |
| Review | a job error was lost when no page waited for it; a reused pid kept the job slot | beta polish: error notice on the next page load; pid checked by command line |
| Review | two core updates could collide; the restart error after a core update was dropped | beta polish: `core.flock`; restart stderr kept |
| Review | long hex `netbird_mark` overflow; `SETTINGS_LOADED` not reset | beta polish |
| User | Traffic lease picker: duplicate and monospace labels, cramped at 390 px; private-MAC hint unclear and shifting the page; Mode text monospace | beta polish: aria-labels, notification naming the device, Mode note as description |
| User | effective YAML visible only over SSH | beta polish: *Show the YAML passed to Mihomo* |

## Deferred (later releases)

### Behaviour
- **Restore after a failed reload loses the older YAML.** `config_install` overwrites `.bak` before the reload; if the reload fails, the rollback puts back the current YAML and the former `.bak` is gone. The same applies to the editor.
- **Provider list URL policy misses some reserved ranges:** `198.18.0.0/15` (the router's own fake-IP range), `192.0.0.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, `fec0::/10` and `64:ff9b::/96`.
- **The list cache is cleaned even when the provider profile is missing or unreadable.** The provider lists' caches are deleted and are re-downloaded on the next update.
- **The runtime lock can outlive a killed holder.** Foreground children of a holder killed with SIGKILL keep it until they exit (seen in the VM: a `sleep` kept it 54 s). Runtime children under the lock are short-lived.
- **Losing the owner file drops the lock.** If the owner file cannot be written (full tmpfs), the lock is dropped without a message. The timeout text then reads `(process )`.
- **Health files can outlive a SIGKILL.** If the supervisor is SIGKILLed, the `health`/`degraded` files stay until the next start. A TERM during startup can leave `last_error` behind.
- **AP mode is treated as WAN.** If the default route is via the LAN bridge (dumb AP), the bridge counts as WAN and its non-RFC1918 subnets are not excluded. This is inherent to the specified algorithm.

### UI (theme-only rule kept)
- **The "?" icon before field descriptions sits higher than the text:** theme rendering (footstrap). VM check 2026-10-23: the same offset (icon top 1 px above the glyph) on MihoWRT pages and on stock Network → DHCP and System. No MihoWRT change.
- **footstrap names both lease picker dropdowns after the field title** ("Devices always direct"): its `fs-select.js` replaces native selects with `ui.Dropdown` and sets `aria-label` from `.cbi-value-title`, ignoring the select's own `aria-label` (same on stock pages). Report upstream; other themes use our names.
- **The private-MAC notification is out of view at 390 px** (LuCI puts it at the top of the page; at 1440 px in openwrt-2020/bootstrap the picker moves down 60–90 px). Kept as decided (notification, no shift under the field); it is announced to screen readers (`role="status"`).
- **`api.job`/`api.jobNotice` rely on `this`**, so a destructured call would break them. No such caller exists.

### Tests and tooling
- **IPv6 validator test:** it lacks a bad-prefix case (`1::/129`).
- **No lint for the awk generator:** `tests/run.sh` lints only `*.sh`, so `mihomo-config.awk` is checked only by the golden outputs.
- **The fd 9 static check is line-based:** a background shell function started under the lock would not be caught (none exists).
- **Weak test:** "API wait does not acquire held lock" in `test_config.sh` does not assert the lock depth.
- **Missing tests:**
  - no test that empty MAC lists render no MAC rules;
  - no `lists-json` test with quotes or CRLF;
  - "`nft_apply` once" after a partial apply is not asserted.
- **Weak overview test:** "Update Mihomo core" uses `notify`, not a reload notice, and has no notice-text test.
- **Small code cleanups:**
  - the init script still has a literal `MIHOWRT="/usr/bin/mihowrt"` next to `SUPERVISOR_CMD`.

## Notes for the release run
- **Release order** (README *Development*): `git tag v0.10.0-rc1 && git push origin v0.10.0-rc1` (pre-release), check the workflow output, then `git tag v0.10.0 && git push origin v0.10.0`, wait for the release workflow, then `git push origin main`.
- **Leftover after upgrade:** `/etc/config/mihowrt.apk-new` stays after upgrades, because the shipped UCI file changed (`lists_interval` default). This is normal apk behaviour.
- **Router test caveat:** the restore check swaps to the previous YAML; if that YAML is an older subscription in another mode, the whole LAN switches mode for a few seconds.
- **Router acceptance evidence:** `.build/router-0100/`. **VM evidence:** `.build/verification-0100/` (neither is in git).
