#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
cp -R "$MIHOWRT_LIB_DIR" "$tmpdir/lib"
export MIHOWRT_LIB_DIR="$tmpdir/lib" AUTO_JOB_TEST_DIR="$tmpdir"
cat >>"$tmpdir/lib/constants.sh" <<'CONSTANTS'
PKG_STATE_DIR="$AUTO_JOB_TEST_DIR/run"
JOBS_DIR="$PKG_STATE_DIR/jobs"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
CONSTANTS
cp "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$tmpdir/mihowrt"
sed -i "s|/usr/bin/mihowrt job-run|$tmpdir/mihowrt job-run|g" "$tmpdir/lib/job.sh"
chmod +x "$tmpdir/mihowrt"
mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/logger" <<'LOGGER'
#!/bin/sh
echo "$*" >>"$AUTO_JOB_TEST_DIR/log"
LOGGER
chmod +x "$tmpdir/bin/logger"
export PATH="$tmpdir/bin:$PATH"
cat >>"$tmpdir/lib/service.sh" <<'SERVICE'
auto_update() {
 local i=0
 [ ! -e /proc/$$/fd/8 ] && [ ! -e /proc/$$/fd/9 ] || { err 'operation inherited lock'; return 1; }
 echo entered >>"$AUTO_JOB_TEST_DIR/operations"
 while [ -f "$AUTO_JOB_TEST_DIR/hold" ] && [ "$i" -lt 200 ]; do
  sleep 0.02
  i=$((i + 1))
 done
 printf '{}\n'
}
lists_refresh() { auto_update; }
SERVICE
cli() { "$tmpdir/mihowrt" "$@"; }
wait_entered() {
 for _ in {1..100}; do [ ! -f "$tmpdir/operations" ] || return 0; sleep 0.02; done
 fail 'job operation did not start'
}
wait_finished() {
 for _ in {1..200}; do
  status="$(cli job-status "$id")"
  if [ "$(jq -r .state <<<"$status")" != running ]; then
   assert_eq ok "$(jq -r .state <<<"$status")" "job finished successfully: $status"
   return 0
  fi
  sleep 0.02
 done
 fail 'job did not finish'
}

# A live LuCI operation keeps its slot; cron skips without an error exit.
if [ "${1:-all}" != cron ]; then
touch "$tmpdir/hold"
id="$(cli job-start update-lists | jq -r .id)"
wait_entered
cli auto-update >"$tmpdir/tick.out" 2>"$tmpdir/tick.err"
assert_eq "$id" "$(readlink "$tmpdir/run/jobs/active")" 'busy tick preserves active job'
assert_file_contains "$tmpdir/log" 'skipped: another operation is running' 'busy cron tick logs skip'
assert_eq 1 "$(wc -l <"$tmpdir/operations" | tr -d ' ')" 'busy cron tick runs no operation'
assert_eq '' "$(cat "$tmpdir/tick.out")" 'busy cron has no job result'
assert_eq '' "$(cat "$tmpdir/tick.err")" 'busy cron is not an error'
rm "$tmpdir/hold"
wait_finished
pass 'auto-update skips a live LuCI job'
fi
[ "${1:-all}" != busy ] || exit 0

# Cron claims the same slot and exposes its job state while downloads run.
rm -f "$tmpdir/operations"
touch "$tmpdir/hold"
cli auto-update >"$tmpdir/tick.out"
assert_eq '' "$(cat "$tmpdir/tick.out")" 'cron job start is silent'
wait_entered
id="$(readlink "$tmpdir/run/jobs/active")"
status="$(cli job-status "$id")"
assert_eq auto-update "$(jq -r .op <<<"$status")" 'cron job operation name'
assert_eq running "$(jq -r .state <<<"$status")" 'cron job remains live'
assert_false 'LuCI job cannot run beside cron' cli job-start update-lists >"$tmpdir/busy.out" 2>"$tmpdir/busy.err"
assert_file_contains "$tmpdir/busy.err" 'Another operation is running: auto-update' 'LuCI sees cron slot'
assert_eq 1 "$(wc -l <"$tmpdir/operations" | tr -d ' ')" 'rejected LuCI job runs no operation'
rm "$tmpdir/hold"
wait_finished
assert_false 'cron completion releases slot' test -L "$tmpdir/run/jobs/active"
pass 'auto-update owns and completes a job without retaining lock fds'
