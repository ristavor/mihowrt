#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backend="$tmpdir/backend"
cat >"$backend" <<'B'
#!/bin/sh
echo "backend $*"
B
chmod +x "$backend"
read_cli="$ROOT_DIR/rootfs/usr/bin/mihowrt-read"

assert_eq "backend status-json" "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" status-json)" "read command passes"
assert_eq "backend read-config /tmp/mihowrt-config.abc" "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" read-config /tmp/mihowrt-config.abc)" "temp config read"
for bad in "select-proxy a b" "save-config /tmp/x" "read-config /etc/hosts" "status-json extra" "core-update" "profile-json x"; do
	# shellcheck disable=SC2086
	if MIHOWRT_BACKEND="$backend" sh "$read_cli" $bad >/dev/null 2>&1; then
		fail "read wrapper must reject: $bad"
	fi
done
pass "read wrapper rejects writes"

out="$(sh "$ROOT_DIR/rootfs/usr/bin/mihowrt" bogus 2>&1 || true)"
[[ "$out" == *"Usage: mihowrt"* ]] || fail "usage on unknown command: $out"
pass "cli usage"

assert_eq 'backend profile-json' "$(MIHOWRT_BACKEND="$backend" sh "$read_cli" profile-json)" "profile-json read wrapper"
# Execute dispatch with the normal module bootstrap removed, not a duplicated case.
strip_mihowrt_cli_bootstrap >"$tmpdir/cli.sh"
export MIHOWRT_LIB_DIR
for n in 1 2 3 4; do printf '%s\n' "$n" >"$tmpdir/list$n"; done
# The real CLI argument boundary is exercised with a harmless apply stub.
sed -i '/^case "$cmd" in/i lists_apply() { printf "lists:%s:%s:%s:%s\\n" "$1" "$2" "$3" "$4"; }' "$tmpdir/cli.sh"
assert_eq "lists:$tmpdir/list1:$tmpdir/list2:$tmpdir/list3:$tmpdir/list4" "$(sh "$tmpdir/cli.sh" apply-lists "$tmpdir/list1" "$tmpdir/list2" "$tmpdir/list3" "$tmpdir/list4")" "four list CLI args"
assert_false "three lists rejected" sh "$tmpdir/cli.sh" apply-lists a b c >/dev/null 2>&1
sed -i '/^case "$cmd" in/i subscription_update() { printf "update:%s\\n" "$1"; }' "$tmpdir/cli.sh"
assert_eq 'update:https://new.example/sub' "$(sh "$tmpdir/cli.sh" update-subscription https://new.example/sub)" 'update URL forwarded'
assert_false 'extra update args rejected' sh "$tmpdir/cli.sh" update-subscription a b >/dev/null 2>&1
pass 'optional subscription URL CLI boundary'

# Run real core_update_cmd and dispatch, substituting only update/service edges.
strip_mihowrt_cli_bootstrap >"$tmpdir/core-cli.sh"
sed -i 's|/etc/init.d/mihowrt restart|"$INIT_STUB" restart|' "$tmpdir/core-cli.sh"
cat >"$tmpdir/init" <<'I'
#!/bin/sh
[ "$1" = restart ] || exit 99
sleep 0.1
echo restarted >"$RESTART_MARKER"
exit "$RESTART_RC"
I
chmod +x "$tmpdir/init"
export INIT_STUB="$tmpdir/init" RESTART_MARKER="$tmpdir/restarted"
sed '/^cmd=/,$d' "$tmpdir/core-cli.sh" >"$tmpdir/core-prefix.sh"
cat >>"$tmpdir/core-prefix.sh" <<'STUBS'
core_update_json() { command printf '{"updated":%s,"version":"v1.19.32","error":null}\n' "$UPDATED"; return "$UPDATE_RC"; }
service_running() { [ "$RUNNING" = 1 ]; }
printf() {
 if [ "$1" = '%s\n' ] && [ "${EXPECT_RESTART:-0}" = 1 ] && [ ! -f "$RESTART_MARKER" ]; then
  echo 'printed before restart finished' >"$EARLY_PRINT"
 fi
 command printf "$@"
}
STUBS
sed -n '/^cmd=/,$p' "$tmpdir/core-cli.sh" >>"$tmpdir/core-prefix.sh"
mv "$tmpdir/core-prefix.sh" "$tmpdir/core-cli.sh"
export UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=0 EXPECT_RESTART=1 EARLY_PRINT="$tmpdir/early"
out="$(sh "$tmpdir/core-cli.sh" core-update)"
assert_false 'CLI prints only after foreground restart' test -e "$EARLY_PRINT"
assert_eq true "$(jq -r .restarted <<<"$out")" 'successful restart reported'
for scenario in stopped unchanged update_failure restart_failure; do
 rm -f "$RESTART_MARKER" "$EARLY_PRINT"
 export UPDATED=true UPDATE_RC=0 RUNNING=1 RESTART_RC=0 EXPECT_RESTART=0
 case "$scenario" in
 stopped) export RUNNING=0 ;;
 unchanged) export UPDATED=false ;;
 update_failure) export UPDATE_RC=1 ;;
 restart_failure) export RESTART_RC=1 EXPECT_RESTART=1 ;;
 esac
 rc=0
 out="$(sh "$tmpdir/core-cli.sh" core-update 2>"$tmpdir/core.err")" || rc=$?
 assert_eq false "$(jq -r .restarted <<<"$out")" "$scenario not restarted"
 case "$scenario" in
 restart_failure)
  assert_eq 1 "$rc" 'restart failure status'
  assert_eq true "$(jq -r .updated <<<"$out")" 'updated kept on restart failure'
  assert_eq v1.19.32 "$(jq -r .version <<<"$out")" 'version kept on restart failure'
  assert_eq 'Mihomo core updated, but the service restart failed' "$(jq -r .error <<<"$out")" 'clear restart error in JSON'
  assert_file_contains "$tmpdir/core.err" "Error: $(jq -r .error <<<"$out")" 'restart error in stderr'
  ;;
 update_failure) assert_eq 1 "$rc" 'update failure status' ;;
 *) assert_eq 0 "$rc" 'no-op status' ;;
 esac
 [ "$scenario" = restart_failure ] || assert_false 'no restart when unnecessary' test -e "$RESTART_MARKER"
done
pass 'core CLI synchronous restart and result'
