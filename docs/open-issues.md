# MihoWRT open issues

State of the 0.11.0 stable-review documentation checkpoint (2026-10-28). This is not release approval or physical-router acceptance. See [reference limits](reference.md#known-limits) and [release procedure](development.md#versioning-and-releases).

## Addressed in this source tree

- **D1 / subscription rollback:** YAML backup rotates only after a successful install/reload/policy apply. A failed apply restores the pre-install YAML/runtime/profile; a failed restore reports and retains recovery files.
- **D6 / stale health:** start clears old health, degraded and error state before launching the supervisor.
- **D15 / concurrent cron:** auto-update uses the LuCI job slot; a busy tick skips instead of competing with a running operation.
- **Diagnostics IPv6 flag:** shows whether the configured client IPv6 block is in effect in the current mode.
- **Large-list resolve:** one classification pass replaces repeated per-family passes. VM 10 000-entry comparisons showed reduced resolve time; that is not a physical-router timing guarantee. Unchanged policy and runtime generation are skipped on reload.
- **Core-update memory:** temporary compressed data is removed before validation; candidate tests remain memory-limited. Core updates succeeded in the 128 MiB VM with ≈6–8 MiB minimum MemAvailable. This closes the review change, not all low-memory capacity concerns (see below).
- **Stable-review fixes:** inbound replies bypass interception, policy priorities use 50–99, kernel-disabled IPv6 does not block IPv4 start, subscription policy rollback and persistent-file publication are safer, remote-cache/job-log budgets are bounded, UI jobs preserve unsaved edits, and the dashboard is opt-in. APK upgrades/reinstalls remove `.apk-new` defaults; read-only actions and upload ACLs were tightened.
- **Earlier checkpoint items:** provider URL range policy (D2), keeping caches when the profile is unreadable (D3), test coverage gaps (D10), Docker-only SDK build (D13), pinned Actions (D16). D9 (`api.job`/`api.jobNotice` depend on `this`) was dropped because no caller destructures them.

## Still deferred

### Runtime and capacity

- **D4. A killed runtime-lock holder's foreground child may retain the lock until exit.** Checkpoint C1 kept L0: no new failure evidence justifies a lock redesign; normal locked children are short-lived.
- **D5. Failure to write the lock owner file can silently drop the lock.** Also kept at L0 by C1; the timeout may say `(process )`. No new evidence changed that decision.
- **D7. Dumb AP mode follows WAN detection.** A default route through the LAN bridge makes that bridge WAN; non-RFC1918 connected subnets on it are not excluded. Inherent in the algorithm, documented rather than redesigned.
- **Large YAML on 128 MiB:** the 8 MiB fixture exhausted memory in all tested builds, including 0.10. Keep YAML small on 128 MiB; several-MiB configs need 256 MiB+. 512 MiB succeeded, 256 MiB was not measured. An upload limit does not promise enough runtime RAM.
- **Unconfirmed physical-router memory-leak report:** investigation postponed by the user, not claimed fixed by resource optimisations.

### UI (theme-owned rendering)

- **D8. Description `?` icon alignment in footstrap:** also observed on stock LuCI pages. No app styling workaround under the theme-only rule.
- **D8. footstrap lease picker labels:** its dropdown replacement takes the field title instead of the select's own `aria-label`, also on stock pages. Upstream/theme issue; other themes use the supplied names.

### Maintenance and distribution

- **D12. Separate shell and awk validators:** retained deliberately, with parity tests; no shared-validator rewrite.
- **D14. Packages are not signed; no signed opkg feed.** Key management needs a separate decision. Installer `SHA256SUMS` protects download integrity, not release authenticity.
- **fd 9 static check:** line-based; it would not catch a background shell function started under a lock (none currently exists).

## Acceptance boundaries / not checked here

- OpenWrt 24.10 was accepted in the QEMU VM only (24.10.8, 512 MiB): package hooks, runtime, network rows, LuCI and core update. A 128 MiB 24.10 guest and `sysupgrade -k` on 24.10 were not tested. See the [24.10 limits](reference.md#openwrt-2410).
- No physical-router F3 approval, real NetBird peers, split DNS/reconnect across NAT, hardware offloading or previously offloaded flows are claimed from synthetic VM evidence.
- Telegram's reported IPv6/direct-first hang is not confirmed fixed: an IPv6 refusal does not prove application IPv4 fallback on the affected client.
- Russian responsive/theme visual acceptance remains separate from string coverage. The synthetic QEMU harness cannot prove physical-router throughput or memory peaks; a safe sysupgrade backup/restore check is not an actual firmware-flash test.
- Main-table-only connected-network exclusions, DoH/DoT bypass, redirect trust and the non-persistent client IPv6 block remain [documented limits](reference.md#known-limits).

Tagging, pushing, publishing and physical-router checks require explicit approval. No release status follows from this checklist.
