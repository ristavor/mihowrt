# MihoWRT open issues

State after the 0.10.0 work (branch `feat/0.10.0`, 2026-10-22). The release is not tagged or pushed yet.
Each item says where it comes from: a review, VM verification (OpenWrt 25.12.6 x86/64) or the router acceptance run on wr3000s.

## Needs a decision

1. **The Mihomo core cannot be updated on routers with little flash.**
   - **Seen on:** wr3000s, overlay 94 MiB, core 54.8 MiB, 57 MiB free.
   - **Symptom:** `core-update` fails with `not enough flash: need 58 MiB, free 57 MiB`.
   - **Cause:** the check needs the uncompressed size plus 4 MiB next to the old binary, and does not count UBIFS compression.
   - **Not a regression:** the same logic was in 0.9.
   - **Options:**
     - (a) Download and unpack into tmpfs, then replace the binary in place. On RAM-poor routers this risks OOM, and an interrupted copy leaves no core.
     - (b) Stop Mihomo, delete the old binary, then write the new one. This needs a rollback copy somewhere.
     - (c) Keep the check and document how to update the core by hand.
   - **Next step:** needs its own design.
2. **Upgrading from 0.9.x stops the old service slowly.**
   - **Seen on:** the router, about 50 s with routing direct.
   - **Cause:** the old 0.9.1 Mihomo outlived its supervisor during the apk upgrade, and `wait-stopped` waited for its 35 s cap.
   - **Effect:** only upgrades from 0.9.x are affected. A 0.10.0 → 0.10.0 replace took about 6 s.
   - **Decision needed:** accept it (one-time), or kill a stray Mihomo by pid after a short grace period in `service_wait_stopped`.
3. **The provider list URL policy checks only the first URL.**
   - **Problem:** curl follows redirects (`-L`), so a public https URL can redirect to a private address.
   - **Why redirects stay:** GitHub release links need them.
   - **Options:** check the final address with `curl -w %{url_effective}`/`%{remote_ip}` and drop the result if it is private, or document the limit only.
4. **The release workflow has never run.**
   - The first `v*` tag is its first run: SDK download and build on ubuntu-latest, then publish.
   - **Decision needed:** whether to tag a pre-release first (e.g. `v0.10.0-rc1`, after allowing such tags in the version check) or go straight to `v0.10.0`.

## Found during 0.10.0 testing and fixed (for the record)

| Where | Problem | Fix |
|---|---|---|
| VM | `cgi-upload` refuses an empty file: clearing a list failed to save | `340a3e51` sends a blank line |
| VM | apk post-upgrade runs `default_postinst` (`init.d start` with the skip marker) before our postinst; procd then stops the running instance and the service stayed stopped | `d5ced47d` preinst marker |
| VM | `apk del` deleted the package-owned `config.yaml` and `lst/*.txt` | `4bfda6f8` prerm `.keep` copies, postrm restore |
| VM browser | the first list-only Save & Apply removed default-valued flags and started a LuCI rollback apply; stray `null` text on Traffic | `d1d2e1ae` |
| Final review | an expired session showed "Lost connection" instead of "Access denied"; `apply-lists` deleted any path given to it | `1f438cfb` |
| Router | notices were lost on the page reload; the first Traffic save after a 0.9.1 upgrade wrote three flags and started a rollback apply | `7e43869b`, `ee05f6b7` |

## Deferred (later releases)

### Behaviour
- **Restore after a failed reload loses the older YAML.** `config_install` overwrites `.bak` before the reload; if the reload fails, the rollback puts back the current YAML and the former `.bak` is gone. The same applies to the editor.
- **Provider list URL policy misses some reserved ranges:** `198.18.0.0/15` (the router's own fake-IP range), `192.0.0.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, `fec0::/10` and `64:ff9b::/96`.
- **The list cache is cleaned even when the provider profile is missing or unreadable.** The provider lists' caches are deleted and are re-downloaded on the next update.
- **A rejected provider list URL is logged several times per apply**, because `lists_source` is called repeatedly.
- **A finished job is reported only by a page reload.** If a job ended with an error while the page was closed, the error text is never shown; the page just reloads.
- **Job liveness is checked by pid only** (`kill -0`). A reused pid keeps the slot "running" until that process exits. `/proc/<pid>/cmdline` could be checked instead.
- **The runtime lock can outlive a killed holder.** Foreground children of a holder killed with SIGKILL keep it until they exit (seen in the VM: a `sleep` kept it 54 s). Runtime children under the lock are short-lived.
- **Losing the owner file drops the lock.** If the owner file cannot be written (full tmpfs), the lock is dropped without a message. The timeout text then reads `(process )`.
- **Two core updates at the same time can collide.** A CLI `core-update` over SSH and a UI job can run together; each run starts by deleting the other's temporary files. Only the UI side is serialised by the job slot.
- **The stderr of the restart after a core update is discarded**, so the reason for a failed restart is lost.
- **Health files can outlive a SIGKILL.** If the supervisor is SIGKILLed, the `health`/`degraded` files stay until the next start. A TERM during startup can leave `last_error` behind.
- **AP mode is treated as WAN.** If the default route is via the LAN bridge (dumb AP), the bridge counts as WAN and its non-RFC1918 subnets are not excluded. This is inherent to the specified algorithm.
- **A long hex `netbird_mark` can overflow the shell arithmetic.** A value over 16 hex digits overflows `$(( ))` in `is_valid_uint32_mark` (admin input only).
- **`settings_load` does not reset `SETTINGS_LOADED` at the start.** Not reachable today.

### UI (theme-only rule kept)
- **The lease picker is cramped on Traffic at 390 px.** The "Add as" select is cut off (`MAC address (IPv4 and IPv6`) and the two picker labels wrap; on openwrt-2020 at 1440 "Add as" wraps under "Add a device". Seen in footstrap and openwrt-2020.
- **The footstrap theme renders the Mode text and picker labels in monospace** (a theme rule on `.cbi-value-field *`). No MihoWRT action needed.
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
  - the init script still has a literal `MIHOWRT="/usr/bin/mihowrt"` next to `SUPERVISOR_CMD`;
  - `migrate_list_headers` rewrites files without keeping their mode.

## Notes for the release run
- **Release order** (README *Development*): `git tag v0.10.0 && git push origin v0.10.0`, wait for the release workflow, then `git push origin main`.
- **Leftover after upgrade:** `/etc/config/mihowrt.apk-new` stays after upgrades, because the shipped UCI file changed (`lists_interval` default). This is normal apk behaviour.
- **Router test caveat:** the restore check swaps to the previous YAML; if that YAML is an older subscription in another mode, the whole LAN switches mode for a few seconds.
- **Router acceptance evidence:** `.build/router-0100/`. **VM evidence:** `.build/verification-0100/` (neither is in git).
