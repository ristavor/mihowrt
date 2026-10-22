#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
[[ -f "$MIHOWRT_LIB_DIR/job.sh" ]] || fail 'job.sh backend is missing'
cp -R "$MIHOWRT_LIB_DIR" "$tmpdir/lib"
export MIHOWRT_LIB_DIR="$tmpdir/lib" JOB_TEST_DIR="$tmpdir"
cat >>"$tmpdir/lib/constants.sh" <<'C'
PKG_STATE_DIR="$JOB_TEST_DIR/run"
JOBS_DIR="$PKG_STATE_DIR/jobs"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
C
cp "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$tmpdir/mihowrt"
# Substitute external process boundaries only; use the real CLI and job module.
sed -i "s|/usr/bin/mihowrt job-run|$tmpdir/mihowrt job-run|g" "$tmpdir/lib/job.sh"
sed -i "s|/etc/init.d/mihowrt|$tmpdir/init|g" "$tmpdir/lib/subscription.sh" "$tmpdir/lib/job.sh" "$tmpdir/mihowrt"
chmod +x "$tmpdir/mihowrt"
cat >"$tmpdir/init" <<'I'
#!/bin/ash
# An init child takes a NEW lock fd: holding the runtime lock here deadlocks.
exec 9>>"$JOB_TEST_DIR/run/runtime.flock"
flock -n 9 || { echo 'init inherited runtime lock' >&2; exit 1; }
exec 8>>"$JOB_TEST_DIR/run/jobs/state.flock"
# Status polling may briefly own this lock; waiting must not deadlock init.
flock 8
echo "init $*" >>"$JOB_TEST_DIR/order"
exit 0
I
chmod +x "$tmpdir/init"
cat >>"$tmpdir/lib/service.sh" <<'S'
lists_refresh() {
 echo entered >"$JOB_TEST_DIR/entered"
 sleep "$(cat "$JOB_TEST_DIR/delay")"
 case "$(cat "$JOB_TEST_DIR/mode")" in
 error) echo 'Error: Mihomo rejected the configuration' >&2; return 1 ;;
 silent-error) return 1 ;;
 text) echo not-json ;;
 empty) ;;
 lines) i=0; while [ "$i" -lt 25 ]; do echo "Error: line $i" >&2; i=$((i + 1)); done; return 1 ;;
 *) echo '{"changed":true}' ;;
 esac
}
subscription_update() {
 echo "subscription_update $*" >>"$JOB_TEST_DIR/order"
 [ "$(cat "$JOB_TEST_DIR/mode")" != error ] || { err 'Update failed'; return 1; }
 echo '{"action":"saved"}'
}
subscription_set() { echo "subscription_set $*" >>"$JOB_TEST_DIR/order"; }
config_api_wait() {
 (exec 7>>"$RUNTIME_LOCK_FILE"; flock -n 7) || { err 'API wait holds runtime lock'; return 1; }
 echo wait >>"$JOB_TEST_DIR/order"
}
config_lock_check() {
 if (exec 7>>"$RUNTIME_LOCK_FILE"; flock -n 7); then
  err 'Config operation lacks runtime lock'; return 1
 fi
}
config_save() { config_lock_check || return 1; echo save >>"$JOB_TEST_DIR/order"; echo '{"action":"saved"}'; }
config_restore() { config_lock_check || return 1; echo restore >>"$JOB_TEST_DIR/order"; echo '{"action":"restored"}'; }
lists_apply() { echo '{"changed":false}'; }
core_update_json() {
 if [ "$(cat "$JOB_TEST_DIR/mode")" = core-restart ]; then
  echo '{"updated":true,"version":"v1","error":null}'
 else
  echo '{"updated":false,"version":"v1","error":null}'
 fi
}
service_running() { [ "$(cat "$JOB_TEST_DIR/mode")" = core-restart ]; }
S
mkdir -p "$tmpdir/run"
echo 0.3 >"$tmpdir/delay"; echo ok >"$tmpdir/mode"
cli() { "$tmpdir/mihowrt" "$@"; }
start_job() { local reply; reply="$(cli job-start "$@")"; id="$(jq -r .id <<<"$reply")"; [[ "$id" =~ ^[0-9]+-[0-9]+$ ]] || fail "invalid start reply: $reply"; }
wait_job() {
 local i
 for i in {1..200}; do
  status="$(cli job-status "$id")"
  [[ "$(jq -r .state <<<"$status")" == running ]] || return 0
  sleep 0.02
 done
 fail "job $id did not finish"
}
start_job update-lists
assert_eq running "$(cli job-status "$id" | jq -r .state)" 'running status'
wait_job
jq -e '.state == "ok" and .result.changed == true and .error == null and .finished >= .started and (keys | sort) == (["id","op","state","started","finished","result","error"] | sort)' <<<"$status" >/dev/null || fail "finished status: $status"
assert_eq 700 "$(stat -c %a "$tmpdir/run/jobs")" 'private jobs directory'
pass 'start and finish'

echo error >"$tmpdir/mode"; start_job update-lists; wait_job
assert_eq error "$(jq -r .state <<<"$status")" 'failed state'
assert_eq 'Mihomo rejected the configuration' "$(jq -r .error <<<"$status")" 'clean error text'
echo silent-error >"$tmpdir/mode"; start_job update-lists; wait_job
assert_eq error "$(jq -r .state <<<"$status")" 'silent failure state'
assert_eq 'The operation failed.' "$(jq -r .error <<<"$status")" 'silent failure fallback'
for mode in text empty lines; do
 echo "$mode" >"$tmpdir/mode"; start_job update-lists; wait_job
 assert_eq null "$(jq -c .result <<<"$status")" "$mode null result"
 if [[ "$mode" == lines ]]; then
  assert_eq 20 "$(jq -r .error <<<"$status" | wc -l | tr -d ' ')" 'last 20 error lines'
  assert_eq 'line 5' "$(jq -r .error <<<"$status" | head -n 1)" 'old errors dropped'
 fi
done
pass 'error text and invalid/empty stdout'

echo ok >"$tmpdir/mode"; echo 3 >"$tmpdir/delay"
# A pipe reader must see EOF within one second, not after the operation ends.
cli job-start update-lists | { IFS= read -r -t 1 reply || fail 'start did not return immediately'; IFS= read -r -t 1 extra && fail "extra stdout: $extra"; rc=$?; [[ "$rc" == 1 ]] || fail 'background job inherited stdout'; echo "$reply" >"$tmpdir/reply"; }
id="$(jq -r .id "$tmpdir/reply")"
rc=0; cli job-start core-update >"$tmpdir/busy.out" 2>"$tmpdir/busy.err" || rc=$?
assert_eq 1 "$rc" 'busy rejected'
assert_eq 'Error: Another operation is running: update-lists' "$(cat "$tmpdir/busy.err")" 'busy error'
wait_job
pass 'detached stdio and busy slot'

# A stopped starter cannot leave fd 9 held by its detached job.
sh -c 'exec 9>>"$1/run/runtime.flock"; flock -n 9; "$1/mihowrt" job-start update-lists' sh "$tmpdir" >"$tmpdir/reply"
id="$(jq -r .id "$tmpdir/reply")"
assert_true 'job child closes lock fd 9' sh -c 'exec 9>>"$1"; flock -n 9' sh "$tmpdir/run/runtime.flock"
wait_job
pass 'detached lock fd'

echo 0 >"$tmpdir/delay"
old=1-99999999
jq -nc --arg id "$old" '{id:$id,op:"update-lists",state:"running",started:1,finished:null,result:null,error:null}' >"$tmpdir/run/jobs/$old.json"
echo 99999999 >"$tmpdir/run/jobs/$old.pid"
ln -s "$old" "$tmpdir/run/jobs/active"
status="$(cli job-status)"
assert_eq error "$(jq -r .state <<<"$status")" 'interrupted state'
assert_eq 'Interrupted: the operation was stopped before it finished.' "$(jq -r .error <<<"$status")" 'interrupted error'
assert_false 'interrupted slot freed' test -L "$tmpdir/run/jobs/active"
start_job update-lists; wait_job
# Also reconcile during start, without a status poll.
cp "$tmpdir/run/jobs/$id.json" "$tmpdir/stale.json"
jq '.state="running" | .finished=null' "$tmpdir/stale.json" >"$tmpdir/run/jobs/$id.json"
echo 99999999 >"$tmpdir/run/jobs/$id.pid"; ln -s "$id" "$tmpdir/run/jobs/active"
start_job update-lists; wait_job
pass 'dead pid reconciliation from status and start'

# Reclaiming a dead slot must not remove a concurrent starter's new slot.
echo 3 >"$tmpdir/delay"
for round in {1..5}; do
 old="1-$round"
 jq -nc --arg id "$old" '{id:$id,op:"update-lists",state:"running",started:1,finished:null,result:null,error:null}' >"$tmpdir/run/jobs/$old.json"
 echo 99999999 >"$tmpdir/run/jobs/$old.pid"
 ln -s "$old" "$tmpdir/run/jobs/active"
 pids=()
 for contender in {1..12}; do
  (cli job-start update-lists >"$tmpdir/contender.$contender.out" 2>"$tmpdir/contender.$contender.err" || true) &
  pids+=("$!")
 done
 for pid in "${pids[@]}"; do wait "$pid"; done
 winners=0
 for contender in {1..12}; do
  if [[ -s "$tmpdir/contender.$contender.out" ]]; then
   id="$(jq -r .id "$tmpdir/contender.$contender.out")"
   winners=$((winners + 1))
  fi
 done
 assert_eq 1 "$winners" 'exactly one concurrent starter reclaims a dead slot'
 wait_job
done
echo 0 >"$tmpdir/delay"
pass 'concurrent dead slot reclamation'

for bad in 'x' 'service reboot' 'connect' 'update-lists extra' 'update-subscription a b' 'apply-lists a b c' 'save-config' 'save-config /etc/passwd' 'apply-lists /etc/passwd - - -' 'connect file:///tmp/x' 'update-subscription javascript:x' 'restore-config x' 'core-update x'; do
 # shellcheck disable=SC2086
 assert_false "reject invalid operation: $bad" cli job-start $bad >/dev/null 2>"$tmpdir/invalid.err"
done
cli job-start x 2>"$tmpdir/invalid.err" && fail 'unknown op succeeded'
assert_file_contains "$tmpdir/invalid.err" 'Unknown operation: x' 'unknown op error'
cli job-start connect 2>"$tmpdir/invalid.err" && fail 'missing URL succeeded'
assert_file_contains "$tmpdir/invalid.err" 'Usage:' 'missing URL usage'
for bad in '../x' '1-2 x' '1-x' '-1' '1-2-3'; do
 # shellcheck disable=SC2086
 assert_false "invalid status: $bad" cli job-status $bad >/dev/null 2>&1
done
assert_false 'job-run rejects traversal' cli job-run ../x update-lists >/dev/null 2>&1
assert_false 'job-run rejects non-slot id' cli job-run 1-2 update-lists >/dev/null 2>&1
pass 'operation and id validation'

# A live owner must persist its actual startup error, not wait for reconciliation.
run_errors=()
for scenario in unknown missing missing-url mismatch; do
 id="$(date +%s)-9999999${#run_errors[@]}"
 jq -nc --arg id "$id" --argjson started "$(date +%s)" '{id:$id,op:"update-lists",state:"running",started:$started,finished:null,result:null,error:null}' >"$tmpdir/run/jobs/$id.json"
 echo "$$" >"$tmpdir/run/jobs/$id.pid"
 ln -s "$id" "$tmpdir/run/jobs/active"
 case "$scenario" in
 unknown) args=(x); expected='Unknown operation: x' ;;
 missing | missing-url)
  args=(); [[ "$scenario" != missing-url ]] || args=(connect)
  expected="$(cli job-start connect 2>&1 || true)"; expected="${expected#Error: }" ;;
 mismatch) args=(restore-config); expected="Job is not active: $id" ;;
 esac
 assert_false "job-run $scenario fails" cli job-run "$id" "${args[@]}" > /dev/null 2>"$tmpdir/run-error"
 status="$(cat "$tmpdir/run/jobs/$id.json")"
 run_errors+=("$(jq -r .state <<<"$status")")
 if [[ "$(jq -r .state <<<"$status")" == error ]]; then
  assert_eq "Error: $expected" "$(cat "$tmpdir/run-error")" "$scenario stderr"
  assert_eq "$expected" "$(jq -r .error <<<"$status")" "$scenario persisted error"
  jq -e '.finished >= .started and .result == null' <<<"$status" >/dev/null || fail "$scenario final status"
  assert_false "$scenario slot freed" test -L "$tmpdir/run/jobs/active"
 fi
 rm -f "$tmpdir/run/jobs/active" "$tmpdir/run/jobs/$id.json" "$tmpdir/run/jobs/$id.pid"
done
assert_eq 'error error error error' "${run_errors[*]}" 'startup failures finalize owned jobs'
# A request for a different id must never finalize or release the active owner.
id=2-9
jq -nc --arg id "$id" '{id:$id,op:"update-lists",state:"running",started:2,finished:null,result:null,error:null}' >"$tmpdir/run/jobs/$id.json"
ln -s 2-10 "$tmpdir/run/jobs/active"
assert_false 'non-owner job-run fails' cli job-run "$id" restore-config >/dev/null 2>&1
assert_eq running "$(jq -r .state "$tmpdir/run/jobs/$id.json")" 'non-owner status untouched'
assert_eq 2-10 "$(readlink "$tmpdir/run/jobs/active")" 'non-owner slot untouched'
rm -f "$tmpdir/run/jobs/active" "$tmpdir/run/jobs/$id.json"
pass 'startup errors finalize only owned jobs'

: >"$tmpdir/order"; start_job connect https://example.com/sub; wait_job
assert_eq ok "$(jq -r .state <<<"$status")" "connect succeeds: $(jq -r .error <<<"$status")"
assert_eq $'subscription_update https://example.com/sub\nsubscription_set https://example.com/sub 1\ninit enable\ninit restart' "$(cat "$tmpdir/order")" 'connect order, init outside runtime lock'
assert_eq saved "$(jq -r .result.action <<<"$status")" 'connect preserves update result'
echo error >"$tmpdir/mode"; : >"$tmpdir/order"; start_job connect https://example.com/sub; wait_job
assert_eq 'subscription_update https://example.com/sub' "$(cat "$tmpdir/order")" 'failed update stops connect'
assert_eq error "$(jq -r .state <<<"$status")" 'connect failure state'
echo ok >"$tmpdir/mode"
start_job service stop; wait_job
assert_eq '{}' "$(jq -c .result <<<"$status")" 'service result'
start_job restore-config; wait_job
assert_eq ok "$(jq -r .state <<<"$status")" "restore holds runtime lock: $(jq -r .error <<<"$status")"
assert_eq restored "$(jq -r .result.action <<<"$status")" 'restore result'
start_job core-update; wait_job
assert_eq false "$(jq -r .result.restarted <<<"$status")" 'core command result'
echo core-restart >"$tmpdir/mode"; : >"$tmpdir/order"; start_job core-update; wait_job
assert_eq true "$(jq -r .result.restarted <<<"$status")" 'core restart result'
assert_eq 'init restart' "$(cat "$tmpdir/order")" 'core restart outside runtime and metadata locks'
echo ok >"$tmpdir/mode"
start_job apply-lists - - - -; wait_job
assert_eq false "$(jq -r .result.changed <<<"$status")" 'apply result'
config_file="$(mktemp /tmp/mihowrt-config.XXXXXX)"
: >"$tmpdir/order"; start_job save-config "$config_file"; wait_job
rm -f "$config_file"
assert_eq ok "$(jq -r .state <<<"$status")" "save holds runtime lock: $(jq -r .error <<<"$status")"
assert_eq saved "$(jq -r .result.action <<<"$status")" 'save result'
assert_eq $'wait\nsave' "$(cat "$tmpdir/order")" 'save waits before lock'
config_file="$(mktemp /tmp/mihowrt-config.XXXXXX)"; rm -f "$config_file"
: >"$tmpdir/order"; start_job restore-config; wait_job
assert_eq ok "$(jq -r .state <<<"$status")" "restore holds runtime lock: $(jq -r .error <<<"$status")"
assert_eq $'wait\nrestore' "$(cat "$tmpdir/order")" 'restore waits before lock'
pass 'whitelisted operation dispatch'

ids=()
for _ in {1..7}; do start_job update-lists; wait_job; ids+=("$id"); done
expected_ids="$(printf '%s\n' "${ids[@]: -5}" | sort)"
actual_ids="$(jq -r .id "$tmpdir/run/jobs/"*.json | sort)"
assert_eq "$expected_ids" "$actual_ids" 'retains the five newest ids'
assert_eq 5 "$(find "$tmpdir/run/jobs" -name '*.json' | wc -l | tr -d ' ')" 'keeps five finished jobs'
assert_eq "$id" "$(cli job-status | jq -r .id)" 'latest job without id'
for ext in pid out err; do
 assert_eq 5 "$(find "$tmpdir/run/jobs" -name "*.$ext" | wc -l | tr -d ' ')" "prunes $ext files"
done
rm -rf "$tmpdir/run/jobs"
assert_eq '{"state":"none"}' "$(cli job-status)" 'empty job history'
pass 'keeps five newest jobs'
