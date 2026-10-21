# MihoWRT 0.9.0 container coverage

Authority: provider-first design spec; implementation-plan Tasks 1–14. This
maps all required behavioral test bullets, not the already completed production
implementation steps or historical red-before-implementation instructions.

| Task | Test files | Required behaviors covered |
| --- | --- | --- |
| 1 | `test_mihomo_config.sh` | Provider redir-host retained; fake range only for fake-ip; external-ui ownership; fake-ip-range6 removed; extension stripped/flow extension rejected; default DNS including emoji/spaces, three bootstrap servers, Yandex, IPv6 true/false; absent/unsafe group suffix dropped; default/provider sniffer; mixed-port retained. |
| 2 | `test_mihomo_config.sh` | Direct-first whitelist and all proxy-first cases; validated scalars; ignored invalid/unknown keys; quoted/commented list items, empty direct list and same-indent items; profile regeneration missing/newer/unchanged without invoking core. |
| 3 | `test_settings.sh`, `test_migration.sh`; updated settings consumers | Generator loaded before settings consumers; provider wins; per-key overrides; stale override harmless; list-source validation; profile-derived mode; missing profile/YAML defaults; obsolete policy_mode deleted. |
| 4 | `test_lists.sh`, `test_provider_update.sh`, `test_cli.sh`, `test_package_hooks.sh` | Provider/merge/own and absent provider sources; invalid provider IP warned/dropped; provider URLs; real four-list installation and CLI arity; fourth-list backup/restore, package install and read ACL. |
| 5 | `test_nft.sh` | NTP fake-IP exceptions; v4/v6 direct devices before catch-all; fake-IP excludes direct-device returns; identical applies skipped, missing table/changed lists reapplied; atomic add/delete/add prefix. |
| 6 | `test_status.sh`, `test_config.sh` | Status does not run core; true/false/error/null/stale check state; actual runtime build records core failure/success and clears old error. |
| 7 | `test_config.sh`, `test_fetch.sh`, `test_provider_update.sh` | Unchanged action and preserved YAML/backup mtimes; extension-only install skips reload; changed profile applies once, same profile does not; API wait retries without taking held lock; rejected formats preserve installed YAML with actionable message, quoted proxies/provider-only accepted; remote lists fetched unlocked before locked nft apply; DNS mode change restarts once, unchanged mode does not. |
| 8 | `test_service.sh` | Three failures with live API degrade/clear marker/continue; next success restores policy/marker; failed API exits 1 for respawn. |
| 9 | `test_service.sh` | Real sourced init Stop creates flag and Start clears it; rewritten-path real hotplug respects flag and starts without it. |
| 10 | `test_mihomo_api.sh`, `test_status.sh`, `test_cli.sh` | Group type/fixed fields (including pinned URLTest), no auto field; encoded DELETE unfix; provider/list/override profile-json; read wrapper allows profile-json only without arguments. |
| 11 | `test_ui.sh` | URLTest/Fallback Auto option/value/selection and editable select; initial fixed selection; LoadBalance disabled/hint; rejected switch restores selection; Test rereads groups and rebuilds delayed options. |
| 12 | `test_ui.sh` | Both derived mode labels/no manual mode; provider scalar/read-only/own dependencies; own flag preserves unrelated overrides; no provider controls without keys; three list sources/count/note/dependencies, no device source; empty own list no note; direct-device readonly hint vs editable redir-host; four uploads in order. |
| 13 | `test_ui.sh`, `test_fetch.sh` | Exact URL and Advanced hints, unchanged update notice; unknown neutral config check/error text; diagnostic profile rows; 12000-character decoded text, oversized/malformed/NUL/non-UTF8 metadata rejected/plain retained; safe HTTP announce links, attributes/text/newlines, unsafe schemes/HTML plain text. |
| 14 | `test_settings.sh`, `test_fetch.sh`, `test_migration.sh`, `test_ui.sh`, `test_provider_update.sh` | Header interval/on-off/missing/default/invalid matrix; first header enables cron/no header removes cron; boolean setter/error; interval migration 0/6/empty with deletion; checkbox state/descriptions and Save boolean; subscription-json auto_update/effective_interval/no interval. |

Review Focus 1–6: group names covered by generator fixtures; broken extension
passes the real subscription-install path; real auto_update whitelist→blacklist
reapplies rendered nft through a stub without restart; profile_ensure regenerates
without a running service; overrides survive provider drop/re-add; fake-ip→
redir-host flushes DNS once (unchanged profile does not).

Validation command:

```sh
docker run --rm -v "$PWD:/workspace:ro" -w /workspace mihowrt-test:local bash tests/run.sh
```

Production fix: ShellCheck SC2015 initially failed `tests/run.sh` for
`lists.sh:lists_resolve` output truncation. Supervisor approved rewriting the
existing `A && B || cleanup` idiom as an equivalent explicit `if ! { A && B; }`.
No runtime semantics changed, and no lint exclusions changed.

Needs decision: none. No behavioral test bullet from Tasks 1–14 remains uncovered.
Real Mihomo YAML acceptance, nft kernel syntax validation and actual router DNS
cache effects are outside these stubbed container tests: the image contains
neither nft nor Mihomo. No installs, SDK, QEMU, router or SSH tests were run.
