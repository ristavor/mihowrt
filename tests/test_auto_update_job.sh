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
SUBSCRIPTION_META_FILE="$AUTO_JOB_TEST_DIR/subscription.json"
CONSTANTS
cp "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$tmpdir/mihowrt"
sed -i '2i [ "${1:-}" != job-run ] || echo spawned >>"$AUTO_JOB_TEST_DIR/spawns"' "$tmpdir/mihowrt"
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
settings_load() {
 SUBSCRIPTION_INTERVAL="${AUTO_TEST_SUB_INTERVAL:-1}"
 SUBSCRIPTION_URL="${AUTO_TEST_SUB_URL-https://sub.example/config}"
 LISTS_INTERVAL="${AUTO_TEST_LISTS_INTERVAL:-0}"
}
lists_source() {
 [ "$1" != dst ] || printf '%s\n' "${AUTO_TEST_LIST_URL:-}"
 return 0
}
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

# Idle ticks must not create metadata or spawn a detached job-run.
if [ "${1:-all}" = all ] || [ "${1:-}" = idle ]; then
for scenario in disabled no_subscription_url fresh_subscription no_remote_lists remote_disabled; do
 export AUTO_TEST_SUB_INTERVAL=0 AUTO_TEST_SUB_URL=https://sub.example/config AUTO_TEST_LISTS_INTERVAL=0 AUTO_TEST_LIST_URL=''
 mkdir -p "$tmpdir/run"
 rm -f "$tmpdir/run/subscription.stamp"
 case "$scenario" in
 no_subscription_url) export AUTO_TEST_SUB_INTERVAL=1 AUTO_TEST_SUB_URL='' ;;
 fresh_subscription)
  export AUTO_TEST_SUB_INTERVAL=1
  touch "$tmpdir/run/subscription.stamp"
  ;;
 no_remote_lists) export AUTO_TEST_LISTS_INTERVAL=1 ;;
 remote_disabled) export AUTO_TEST_LIST_URL=https://lists.example/list.txt ;;
 esac
 cli auto-update >"$tmpdir/tick.out" 2>"$tmpdir/tick.err"
 assert_false "$scenario idle tick leaves jobs directory absent" test -e "$tmpdir/run/jobs"
 assert_false "$scenario idle tick spawns no job-run" test -e "$tmpdir/spawns"
 assert_false "$scenario idle tick runs no operation" test -e "$tmpdir/operations"
 assert_eq '' "$(cat "$tmpdir/tick.out")" "$scenario idle tick is silent"
 assert_eq '' "$(cat "$tmpdir/tick.err")" "$scenario idle tick has no error"
 pass "auto-update idle tick: $scenario"
done
rm -f "$tmpdir/run/subscription.stamp"
unset AUTO_TEST_SUB_INTERVAL AUTO_TEST_SUB_URL AUTO_TEST_LISTS_INTERVAL AUTO_TEST_LIST_URL
fi
[ "${1:-all}" != idle ] || exit 0

# A live LuCI operation keeps its slot; a due cron tick skips without an error exit.
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

# Remote lists alone also make a tick eligible; per-URL age is checked by the job.
rm -f "$tmpdir/operations"
touch "$tmpdir/hold"
AUTO_TEST_SUB_INTERVAL=0 AUTO_TEST_LISTS_INTERVAL=1 AUTO_TEST_LIST_URL=https://lists.example/list.txt cli auto-update
wait_entered
id="$(readlink "$tmpdir/run/jobs/active")"
assert_eq auto-update "$(cli job-status "$id" | jq -r .op)" 'remote lists tick claims auto-update job'
assert_true 'due tick spawns job-run' test -f "$tmpdir/spawns"
rm "$tmpdir/hold"
wait_finished
pass 'auto-update remote lists tick creates a job'
