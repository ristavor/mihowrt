#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh service.sh
setup_runtime_paths "$tmpdir"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
SERVICE_PID_FILE="$PKG_STATE_DIR/pid"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.yaml"
CLASH_BIN="$tmpdir/core"
printf '#!/bin/sh\nexec sleep 30\n' >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
printf 'mode: rule\n' >"$RUNTIME_CONFIG"
settings_load() { :; }
mihomo_memory_limit() { echo 64MiB; }
policy_cleanup() { :; }
cache_db_persist() { :; }
stop_child() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
for scenario in readiness policy; do
 (
  wait_for_ready() { [ "$scenario" != readiness ]; }
  policy_reapply() { err 'nft transaction rejected'; return 1; }
  rc=0
  run_service 2>"$tmpdir/stderr" || rc=$?
  assert_eq 1 "$rc" "$scenario failure is reported"
  if [ "$scenario" = readiness ]; then
   expected='Mihomo did not become ready; router stays on direct routing'
  else
   expected='Failed to apply routing rules: nft transaction rejected'
   assert_file_not_contains "$tmpdir/stderr" 'Mihomo did not become ready' 'policy error is not a readiness error'
  fi
  assert_eq "$expected" "$(cat "$LAST_ERROR_FILE")" "$scenario failure has its own error"
  assert_file_contains "$tmpdir/stderr" "Error: $expected" "$scenario error passed to stderr"
  assert_false 'startup error temporary file removed' test -e "$LAST_ERROR_FILE.err.$$"
 )
 pass "startup error: $scenario"
done
