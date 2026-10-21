# Review-fix regression evidence (196943ef)

`test_review_fixes.sh` runs 17 isolated cases, continuing after failures so every
regression is exercised on the parent. Run one case with, for example,
`bash tests/test_review_fixes.sh watchdog_settings`. `tests/run.sh` discovers it
automatically. Only runtime dependencies are stubbed; the functions under test
are loaded from the mounted checkout.

## Checked results

All cases below failed on `196943ef^` (`97d945ee`) and passed on `196943ef`.
The parent run exited 1; the HEAD suite exited 0, including shell syntax/lint.

| Item | Case(s) | Parent failing assertion / observed value |
| --- | --- | --- |
| 1 | `startup_settings`, `watchdog_settings` | Startup expected proxy-first, got direct-first; recovery expected direct-first then proxy-first, got direct-first twice |
| 2 | `auto_update_ready`, `lists_refresh_ready` | No nft without marker: expected empty, got nft |
| 3 | `dns_comment`, `extension_comment`, `list_comment`, `groups_comment` | provider block kept; settings parsed; address parsed; first group DNS suffix |
| 4 | `indentless_groups` | first group DNS suffix (HEAD also checks group items byte-for-byte) |
| 5 | `profile_race` | Expected reader then policy, got reader only |
| 6 | `empty_dns_next`, `empty_dns_comments` | managed DNS absent |
| 7 | `curl_device`, `curl_plain` | curl argv missing globoff (-g) |
| 7 | `lists_star`, `lists_brackets` | Expected literal list* / list[1-3] URL, got list1 |
| 8 | `single_quote` | first group DNS suffix |

## Commands

Executed from the repository root, using only the test container:

```sh
colima status >/dev/null 2>&1 || colima start
docker build -t mihowrt-test:local -f Dockerfile.test .
docker run --rm -v "$PWD:/workspace:ro" -w /workspace mihowrt-test:local bash tests/test_review_fixes.sh

git worktree add /Users/peamp/projects/mw-pre 196943ef^
cp tests/test_review_fixes.sh /Users/peamp/projects/mw-pre/tests/
docker run --rm -v /Users/peamp/projects/mw-pre:/workspace:ro -w /workspace mihowrt-test:local bash tests/test_review_fixes.sh
# Expected exit 1, with all 17 named FAIL assertions above.
git worktree remove --force /Users/peamp/projects/mw-pre

docker run --rm -v "$PWD:/workspace:ro" -w /workspace mihowrt-test:local bash tests/run.sh
```

An initial `/tmp/mw-pre` checkout was not visible in Colima's container mount
(`tests/test_review_fixes.sh: No such file or directory`); it was removed and the
actual baseline proof used the visible `/Users/peamp/projects/mw-pre` checkout.
Both temporary worktrees were removed; neither was committed.

Final full-suite last lines:

```text
ok - provider-first Traffic form and save
ok - subscription checkbox, hints, save and unchanged notice
ok - automatic group events and safe announce links
ok - diagnostics unknown/error and profile details
all tests passed
```

All requested items are covered. The optional router/VM harness remains skipped;
no VM, router, or device access was used. Watchdog error messages about the hung
API are deliberate termination stimuli in the tests, not container failures.
