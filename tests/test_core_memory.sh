#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh
setup_runtime_paths "$tmpdir"
CLASH_DIR="$tmpdir/clash"
CLASH_BIN="$tmpdir/core"
export CORE_MEMORY_ENV="$tmpdir/memory.env"
cat >"$CLASH_BIN" <<'CORE'
#!/bin/sh
[ "$1" != -v ] || { echo 'Mihomo v1.2.3'; exit 0; }
printf '%s\n' "${GOMEMLIMIT:-unset}" >"$CORE_MEMORY_ENV"
CORE
chmod +x "$CLASH_BIN"
# Rewrite only this test copy; production has no environment-controlled proc path.
sed "s|/proc/self/oom_score_adj|$tmpdir/oom_score_adj|g" "$MIHOWRT_LIB_DIR/mihomo-config.sh" >"$tmpdir/config-test.sh"
source "$tmpdir/config-test.sh"
export CORE_OOM_FILE="$tmpdir/oom_score_adj"
printf '\ncat "$CORE_OOM_FILE" >"$CORE_MEMORY_ENV.oom" 2>/dev/null || true\n' >>"$CLASH_BIN"
echo 'mode: rule' >"$CLASH_CONFIG"
expected="$(awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo)"
if ! mihomo_config_test "$CLASH_CONFIG" 2>"$tmpdir/test.err"; then
 fail "standalone config test: $(cat "$tmpdir/test.err")"
fi
assert_eq '' "$(cat "$tmpdir/test.err")" 'config test needs no service module and emits no lookup errors'
assert_eq "$expected" "$(cat "$CORE_MEMORY_ENV")" 'config-only modules provide bounded memory'
assert_eq 1000 "$(cat "$CORE_MEMORY_ENV.oom")" 'checker increases OOM priority before core execution'
rm "$CORE_OOM_FILE"
mkdir "$CORE_OOM_FILE"
assert_true 'unwritable OOM score is nonfatal' mihomo_config_test "$CLASH_CONFIG"
pass 'config memory budget works without service module'
# Production bootstrap retains the same helper for the supervisor caller.
mihowrt_load_modules
assert_eq "$(awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo)" "$(mihomo_memory_limit)" 'full production modules keep supervisor memory budget'
pass 'production module set retains memory budget helper'
