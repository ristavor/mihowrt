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

(
 rm -f "$RUNNING_MARKER"
 applied=0
 marker_at_unlock=no
 eval "$(declare -f lock_release | sed '1s/lock_release/real_lock_release/')"
 lock_release() {
  if [ "$applied" = 1 ]; then
   assert_eq 1 "$LOCK_DEPTH" 'startup policy owns runtime lock'
   [ ! -f "$RUNNING_MARKER" ] || marker_at_unlock=yes
   applied=2
  fi
  real_lock_release
 }
 wait_for_ready() { return 0; }
 policy_reapply() {
  assert_eq 1 "$LOCK_DEPTH" 'startup policy applied inside runtime lock'
  applied=1
 }
 WATCHDOG_INTERVAL=0.01
 api_dns_probe() { stop=1; return 0; }
 run_service
 assert_eq 2 "$applied" 'startup readiness publication checked under lock'
 assert_eq yes "$marker_at_unlock" 'startup marker published before releasing policy lock'
)
pass 'startup marker and policy share runtime lock'
