#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh lists.sh job.sh

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
setup_runtime_paths "$tmpdir"
lists_ensure_files
mkdir -p "$POLICY_CACHE_DIR" "$PKG_TMP_DIR"
settings_load() { :; }
service_ready() { return 0; }
with_lock() { "$@"; }
nft_apply() { printf 'apply\n' >>"$tmpdir/applied"; }
http_fetch() {
 case "$mode:$1" in
 all-fail:* | mixed:*fail.example*) FETCH_ERROR=network; return 1 ;;
 esac
 printf '9.9.9.9\n' >"$2"
}

printf '%s\n' https://ok.example/list https://fail.example/list >"$DST_LIST_FILE"
ok_cache="$(lists_cache_file https://ok.example/list)"
fail_cache="$(lists_cache_file https://fail.example/list)"
for mode in mixed all-fail unchanged; do
 printf '9.9.9.9\n' >"$ok_cache"
 [ "$mode" = unchanged ] || printf '1.1.1.1\n' >"$ok_cache"
 printf '9.9.9.9\n' >"$fail_cache"
 [ "$mode" = unchanged ] || printf '8.8.8.8\n' >"$fail_cache"
 : >"$tmpdir/applied"
 rc=0
 lists_refresh >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
 case "$mode" in
 mixed)
  assert_eq 1 "$rc" 'partial refresh returns failure'
  assert_eq apply "$(cat "$tmpdir/applied")" 'partial refresh applies changed cache'
  assert_eq 9.9.9.9 "$(cat "$ok_cache")" 'successful URL cache updated'
  assert_eq 8.8.8.8 "$(cat "$fail_cache")" 'failed URL cache preserved'
  assert_eq 'Error: Failed to update 1 of 2 remote lists: Remote list fetch failed: fail.example (network)' "$(cat "$tmpdir/err")" 'partial refresh reports count and first error'
  ;;
 all-fail)
  assert_eq 1 "$rc" 'all failed refresh returns failure'
  assert_eq '' "$(cat "$tmpdir/applied")" 'all failed refresh does not apply'
  assert_eq 1.1.1.1 "$(cat "$ok_cache")" 'first failed cache preserved'
  assert_eq 8.8.8.8 "$(cat "$fail_cache")" 'second failed cache preserved'
  assert_eq 'Error: Failed to update 2 of 2 remote lists: Remote list fetch failed: ok.example (network)' "$(cat "$tmpdir/err")" 'all failed refresh reports first error'
  ;;
 unchanged)
  assert_eq 0 "$rc" 'unchanged successful refresh returns success'
  assert_eq '{"changed":false}' "$(cat "$tmpdir/out")" 'unchanged successful refresh JSON'
  assert_eq '' "$(cat "$tmpdir/applied")" 'unchanged refresh does not apply'
  assert_eq '' "$(cat "$tmpdir/err")" 'unchanged refresh has no error'
  ;;
 esac
 pass "lists_refresh $mode"
done

# A publication error is a failed URL too, and leaves the old cache intact.
(
 mode=unchanged
 printf '1.1.1.1\n' >"$ok_cache"
 atomic_copy() { return 1; }
 assert_false 'cache write failure fails refresh' lists_refresh >"$tmpdir/out" 2>"$tmpdir/err"
 assert_eq 1.1.1.1 "$(cat "$ok_cache")" 'cache write failure preserves old cache'
 assert_eq 'Error: Failed to update 1 of 2 remote lists: Remote list cache write failed: ok.example' "$(cat "$tmpdir/err")" 'cache write failure counted'
)
pass 'lists_refresh cache write failure'

# Run the real job dispatcher and finalizer around the real failed refresh.
mode=all-fail
JOBS_DIR="$tmpdir/jobs"
job_dir_prepare
id=1-4242
jq -nc --arg id "$id" '{id:$id,op:"update-lists",state:"running",started:1,finished:null,result:null,error:null}' >"$JOBS_DIR/$id.json"
ln -s "$id" "$JOBS_DIR/active"
job_run "$id" update-lists
assert_eq error "$(jq -r .state "$JOBS_DIR/$id.json")" 'failed refresh finishes job with error'
assert_eq 'Failed to update 2 of 2 remote lists: Remote list fetch failed: ok.example (network)' "$(jq -r .error "$JOBS_DIR/$id.json")" 'job exposes refresh failure'
assert_false 'failed refresh releases job slot' test -L "$JOBS_DIR/active"
pass 'lists_refresh failure reaches job status'
