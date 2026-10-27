#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/full" "$tmpdir/service" "$tmpdir/job" "$tmpdir/bin" "$tmpdir/state/jobs"
cp "$MIHOWRT_LIB_DIR"/*.sh "$tmpdir/full/"
for set in service job; do cp "$MIHOWRT_LIB_DIR/"{constants,helpers,validate}.sh "$tmpdir/$set/"; done
cp "$MIHOWRT_LIB_DIR/"{service,status}.sh "$tmpdir/service/"
cp "$MIHOWRT_LIB_DIR/job.sh" "$tmpdir/job/"
# Keep all filesystem reads/writes isolated; both loaders use these constants.
for set in full service job; do
 cat >>"$tmpdir/$set/constants.sh" <<EOF
PKG_STATE_DIR='$tmpdir/state'
JOBS_DIR='$tmpdir/state/jobs'
SERVICE_PID_FILE='$tmpdir/state/pid'
RUNNING_MARKER='$tmpdir/state/running'
USER_STOP_FILE='$tmpdir/state/stopped'
HEALTH_FILE='$tmpdir/state/health'
DEGRADED_FILE='$tmpdir/state/degraded'
LAST_ERROR_FILE='$tmpdir/state/last_error'
CLASH_BIN='/bin/sleep'
JOB_PROC_DIR='$tmpdir/proc'
EOF
 done
printf '#!/bin/sh\necho 1790000000\n' >"$tmpdir/bin/date"
chmod +x "$tmpdir/bin/date"
export PATH="$tmpdir/bin:$PATH"
# Run the same CLI dispatcher, forcing the reference to retain the full set.
sed 's/mihowrt_load_modules "${1:-}"/mihowrt_load_modules/' "$ROOT_DIR/rootfs/usr/bin/mihowrt" >"$tmpdir/full-cli"
cli="$ROOT_DIR/rootfs/usr/bin/mihowrt"

check_output() {
 local set="$1" label="$2"
 shift 2
 MIHOWRT_LIB_DIR="$tmpdir/full" busybox ash "$tmpdir/full-cli" "$@" >"$tmpdir/full.out" 2>"$tmpdir/full.err"
 MIHOWRT_LIB_DIR="$tmpdir/$set" busybox ash "$cli" "$@" >"$tmpdir/narrow.out" 2>"$tmpdir/narrow.err" || {
  cat "$tmpdir/narrow.err" >&2
  fail "$label failed with only its command modules"
 }
 assert_true "$label byte-identical output" cmp -s "$tmpdir/full.out" "$tmpdir/narrow.out"
 assert_true "$label byte-identical stderr" cmp -s "$tmpdir/full.err" "$tmpdir/narrow.err"
 if [ "$set" = service ]; then
  assert_eq "$label" "$(jq -r .state "$tmpdir/narrow.out")" "$label fixture state"
 fi
 pass "CLI modules: $label"
}

check_output service stopped service-state-json
busybox ash -c 'exec /bin/sleep 240' &
service_pid=$!
trap 'kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT
printf '%s\n' "$service_pid" >"$tmpdir/state/pid"
# Wait for exec so /proc cmdline really names the core fixture.
for _ in {1..100}; do
 grep -q /bin/sleep "/proc/$service_pid/cmdline" && break
 sleep 0.01
done
touch "$tmpdir/state/running"
printf 'ok\n' >"$tmpdir/state/health"
check_output service running service-state-json
touch "$tmpdir/state/degraded"
check_output service degraded service-state-json
rm "$tmpdir/state/degraded" "$tmpdir/state/running"
check_output service starting service-state-json
rm "$tmpdir/state/pid"
printf 'start failed\n' >"$tmpdir/state/last_error"
check_output service failed service-state-json

check_output job absent job-status
printf '{"id":"123-456","op":"update-lists","state":"ok","started":123,"finished":124,"result":{},"error":null}\n' >"$tmpdir/state/jobs/123-456.json"
check_output job history job-status
check_output job specific job-status 123-456
printf '{"id":"125-456","op":"update-lists","state":"running","started":125,"finished":null,"result":null,"error":null}\n' >"$tmpdir/state/jobs/125-456.json"
printf '%s\n' "$service_pid" >"$tmpdir/state/jobs/125-456.pid"
mkdir -p "$tmpdir/proc/$service_pid"
printf 'mihowrt\000job-run\000125-456\000' >"$tmpdir/proc/$service_pid/cmdline"
ln -s 125-456 "$tmpdir/state/jobs/active"
check_output job active job-status
# Each stale-job run gets the same pre-reconciliation files.
cp -a "$tmpdir/state/jobs" "$tmpdir/jobs.before"
printf '0\n' >"$tmpdir/state/jobs/125-456.pid"
MIHOWRT_LIB_DIR="$tmpdir/full" busybox ash "$tmpdir/full-cli" job-status >"$tmpdir/full.out"
rm -rf "$tmpdir/state/jobs"
cp -a "$tmpdir/jobs.before" "$tmpdir/state/jobs"
printf '0\n' >"$tmpdir/state/jobs/125-456.pid"
MIHOWRT_LIB_DIR="$tmpdir/job" busybox ash "$cli" job-status >"$tmpdir/narrow.out" 2>"$tmpdir/narrow.err"
assert_true 'stale job byte-identical output' cmp -s "$tmpdir/full.out" "$tmpdir/narrow.out"
assert_false 'stale job has no missing-function errors' test -s "$tmpdir/narrow.err"
pass 'CLI modules: stale job reconciliation'

# Follow project-function references transitively, including callbacks passed
# to lock helpers. A newly introduced dependency must belong to the read set.
node - "$MIHOWRT_LIB_DIR" <<'NODE'
const fs = require('fs');
const dir = process.argv[2];
const functions = new Map();
for (const module of fs.readdirSync(dir).filter(name => name.endsWith('.sh'))) {
 const source = fs.readFileSync(`${dir}/${module}`, 'utf8');
 for (const match of source.matchAll(/^(\w+)\(\) [({][\s\S]*?^[)}]/gm))
  functions.set(match[1], { module, body: match[0] });
}
for (const [root, modules] of [
 ['service_state_json', ['constants.sh', 'helpers.sh', 'validate.sh', 'service.sh', 'status.sh']],
 ['job_status', ['constants.sh', 'helpers.sh', 'validate.sh', 'job.sh']]
]) {
 const visited = new Set();
 function check(name) {
  if (visited.has(name)) return;
  visited.add(name);
  const entry = functions.get(name);
  if (!entry) throw new Error(`missing project function ${name}`);
  if (!modules.includes(entry.module)) throw new Error(`${root} uses ${name} from excluded ${entry.module}`);
  for (const word of entry.body.match(/\b[A-Za-z_][A-Za-z_0-9]*\b/g) || [])
   if (functions.has(word)) check(word);
 }
 check(root);
 console.log(`ok - CLI dependency closure: ${root} (${visited.size} functions)`);
}
NODE
