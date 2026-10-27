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
echo 'mode: rule' >"$CLASH_CONFIG"
expected="$(awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo)"
if ! mihomo_config_test "$CLASH_CONFIG" 2>"$tmpdir/test.err"; then
 fail "standalone config test: $(cat "$tmpdir/test.err")"
fi
assert_eq '' "$(cat "$tmpdir/test.err")" 'config test needs no service module and emits no lookup errors'
assert_eq "$expected" "$(cat "$CORE_MEMORY_ENV")" 'config-only modules provide bounded memory'
pass 'config memory budget works without service module'
# Production bootstrap retains the same helper for the supervisor caller.
mihowrt_load_modules
assert_eq "$(awk '/^MemTotal:/ { print int($2 / 2048) "MiB" }' /proc/meminfo)" "$(mihomo_memory_limit)" 'full production modules keep supervisor memory budget'
pass 'production module set retains memory budget helper'
