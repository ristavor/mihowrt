# MihoWRT open issues

State after 0.11.0 (branch `feat/0.11.0`, 2026-10-27). The release is not tagged or pushed yet.
Each item says where it comes from: a review, VM verification (OpenWrt 25.12.6 x86/64) or the router acceptance run on wr3000s.

## Needs a decision

None.

## Decisions of checkpoint C1 (2026-10-26)

- **Runtime lock (G1): L0.** No lock-related failure in the unit suites, reviews or the VM; 10 `ifupdate` events in under 1 s with a slowed `nft_apply` gave one coalesced `net_refresh`, no `Runtime is busy` and no fd 6/9 leak. The lock code is unchanged; its two limits below are documented, not fixed.
- **Done in 0.11.0:** provider list URL policy (all local and reserved ranges, D2), list cache kept when the profile is unreadable (D3), test gaps (D10), pinned GitHub Actions (D16), Docker-only SDK build (D13), bounded core-test memory (D11).
- **Dropped:** D9 (`api.job`/`api.jobNotice` rely on `this`): no caller destructures them.
- **Client IPv6 flag (user decision):** `block-client-ipv6` is an explicit, provider-controlled, client-only flag. It works only in direct-first mode (*Only selected traffic via proxy*), rejects (TCP reset / ICMPv6 administratively prohibited) non-local client IPv6 that would bypass Mihomo, and is off by default. It does not disable kernel or Mihomo IPv6 and does not guarantee an IPv4 fallback in applications.
- **Devices always direct with fake-IP:** supported through the `mihowrt-direct` listener (port 7895). MihoWRT does not add private or vendor domains to `fake-ip-filter`; domain handling is the provider's job. Provider YAML forms that cannot be extended safely fall back to the old behaviour with one warning.

## Deferred (later releases)

### Behaviour
- **D1. Restore after a failed reload loses the older YAML.** `config_install` overwrites `.bak` before the reload; if the reload fails, the rollback puts back the current YAML and the former `.bak` is gone. The same applies to the editor. Fix idea: keep `.bak` until the reload succeeds.
- **D4. The runtime lock can outlive a killed holder (G1 = L0).** Foreground children of a holder killed with SIGKILL keep it until they exit (seen in the VM: a `sleep` kept it 54 s). Runtime children under the lock are short-lived.
- **D5. Losing the owner file drops the lock (G1 = L0).** If the owner file cannot be written (full tmpfs), the lock is dropped without a message. The timeout text then reads `(process )`.
- **D6. Health files can outlive a SIGKILL.** If the supervisor is SIGKILLed, the `health`/`degraded` files stay until the next start. A TERM during startup can leave `last_error` behind.
- **D7. AP mode is treated as WAN.** If the default route is via the LAN bridge (dumb AP), the bridge counts as WAN and its non-RFC1918 subnets are not excluded. This is inherent to the specified algorithm.
- **D15. Cron auto-update can run next to a LuCI job.** Kept as is for 0.11.0 (C1 decision: keep deferred).
- **Diagnostics does not show whether the IPv6 flag is in effect in the current mode.** The flag is stored, but it has no effect outside direct-first; the page does not say so.
- **Core update memory on 128 MiB routers.** With the bounded test run the lowest free memory seen in the VM during `core-update` is about 6.0 MiB (it was about 4.3 MiB before); no out-of-memory kill in either case. Measured only in the QEMU VM.
- **Unconfirmed router memory-leak report:** not investigated in 0.11.0 (postponed by the user).

### UI (theme-only rule kept)
- **D8. The "?" icon before field descriptions sits higher than the text:** theme rendering (footstrap). VM check 2026-10-23: the same offset (icon top 1 px above the glyph) on MihoWRT pages and on stock Network → DHCP and System. No MihoWRT change.
- **D8. footstrap names both lease picker dropdowns after the field title** ("Devices always direct"): its `fs-select.js` replaces native selects with `ui.Dropdown` and sets `aria-label` from `.cbi-value-title`, ignoring the select's own `aria-label` (same on stock pages). Report upstream; other themes use our names.

### Other
- **D12. Two validator sets.** Shell and awk validate the same values separately; they are kept in sync by tests, not shared code.
- **D14. APKs are not signed.** The installer checks every download against `SHA256SUMS` from the release.

## Acceptance status and limits

- **Done:** container test suite and the repeatable synthetic VM acceptance (`./tests/router/run-network.sh`, evidence in `.build/verification-0110/`, not in git). The synthetic rows are marks, namespaces and a dummy interface; they are not a transport proof.
- **Not tested yet (router acceptance F3, needs the user's yes):** wr3000s run, UI on footstrap (RU, 1440/390 px), real NetBird peers, split DNS and reconnect across NAT. Real NetBird compatibility is **not claimed** from synthetic evidence.
- **Not tested:** hardware offloading and flows offloaded before a policy change. Such connections can continue until their flowtable entries expire; the client IPv6 block is not a persistent kill-switch.
- **Telegram:** the reported hang with IPv6 in direct-first is **not confirmed fixed**. Exact IPv6 refusal does not prove application fallback; the cause and the IPv4 retry stay unverified until a test on the affected client.
- **Main routing table only:** connected-network exclusions read only the main table, not mwan3 or other policy tables.
- **Provider list redirects:** URLs are checked before download only; curl follows redirects (README *Known limits*).

## Release run
Order is in README *Development*: `vX-rc1` as a pre-release first, check the workflow output, then `vX`, wait for the release workflow, then `git push origin main`. Nothing is tagged or pushed without the user's explicit yes.
