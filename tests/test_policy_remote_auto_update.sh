#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat >"$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_UCI_LOG"

if [[ "${1:-}" == "-q" ]]; then
	shift
fi

case "${1:-}" in
	get)
		case "${2:-}" in
			mihowrt.settings.policy_remote_update_interval) printf '%s\n' "${TEST_UCI_POLICY_REMOTE_INTERVAL:-}" ;;
			*) exit 1 ;;
		esac
		;;
	set|delete|commit)
		exit 0
		;;
	*)
		exit 1
		;;
esac
EOF

chmod +x "$tmpbin/logger" "$tmpbin/uci"
export PATH="$tmpbin:$PATH"
export TEST_UCI_LOG="$tmpdir/uci.log"
export TEST_UCI_POLICY_REMOTE_INTERVAL=""

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"

event_log="$tmpdir/events.log"
POLICY_REMOTE_AUTO_UPDATE_STATE_FILE="$tmpdir/policy-remote-auto.state"

update_runtime_policy_lists() {
	printf 'update_runtime_policy_lists\n' >>"$event_log"
	[ "${TEST_POLICY_UPDATE_RC:-0}" -eq 0 ] || return "${TEST_POLICY_UPDATE_RC:-1}"
	printf 'updated=%s\n' "${TEST_POLICY_UPDATED:-1}"
}

assert_true "zero policy remote auto-update interval should be valid" policy_remote_update_interval_valid "0"
assert_true "positive policy remote auto-update interval should be valid" policy_remote_update_interval_valid "24"
assert_false "too large policy remote auto-update interval should be invalid" policy_remote_update_interval_valid "8761"

POLICY_REMOTE_CRON_FILE="$tmpdir/root.cron"
rm -f "$POLICY_REMOTE_CRON_FILE"
policy_remote_sync_auto_update_cron 0
[[ ! -e "$POLICY_REMOTE_CRON_FILE" ]] || fail "policy remote cron sync should not create crontab when disabled and marker is absent"
printf '0 0 * * * echo keep\n23 * * * * /usr/bin/mihowrt auto-update-policy-lists >/dev/null 2>&1 # mihowrt policy remote auto-update\n' >"$POLICY_REMOTE_CRON_FILE"
policy_remote_sync_auto_update_cron 0
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "echo keep" "policy remote cron sync should preserve unrelated entries when disabled"
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "policy remote cron sync should remove auto-update task when disabled"
policy_remote_sync_auto_update_cron 1
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "policy remote cron sync should create auto-update task only when enabled"
policy_cron_inode="$(stat -c %i "$POLICY_REMOTE_CRON_FILE")"
policy_remote_sync_auto_update_cron 1
assert_eq "$policy_cron_inode" "$(stat -c %i "$POLICY_REMOTE_CRON_FILE")" "policy remote cron sync should not rewrite unchanged enabled task"
policy_remote_sync_auto_update_cron 0
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "policy remote cron sync should remove auto-update task after interval becomes disabled"

: >"$TEST_UCI_LOG"
: >"$POLICY_REMOTE_CRON_FILE"
TEST_UCI_POLICY_REMOTE_INTERVAL=0
printf 'next_update=123\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
policy_remote_refresh_auto_update_state
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "refresh should not create cron when interval is zero"
[[ ! -e "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" ]] || fail "refresh should remove tmpfs state when interval is zero"

: >"$TEST_UCI_LOG"
: >"$POLICY_REMOTE_CRON_FILE"
TEST_UCI_POLICY_REMOTE_INTERVAL=6
policy_remote_refresh_auto_update_state
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "refresh should create cron for positive interval"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "interval=6" "refresh should write tmpfs schedule state for positive interval"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "next_update=" "refresh should store next update in tmpfs"
printf 'interval=6\nlast_update=1\nnext_update=123\nlast_result=scheduled\nreason=\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
policy_remote_refresh_auto_update_state
assert_eq "123" "$(policy_remote_state_value next_update)" "refresh should preserve next update when interval is unchanged"

: >"$TEST_UCI_LOG"
printf 'next_update=123\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
TEST_UCI_POLICY_REMOTE_INTERVAL=9999
policy_remote_refresh_auto_update_state
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "refresh should remove cron when interval is invalid"
[[ ! -e "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" ]] || fail "refresh should remove tmpfs state when interval is invalid"

: >"$event_log"
TEST_UCI_POLICY_REMOTE_INTERVAL=4
policy_remote_write_auto_update_state 4 "scheduled" ""
auto_update_output="$(auto_update_policy_remote_lists)"
assert_eq "updated=0" "$auto_update_output" "auto updater should no-op before next update time"
assert_file_not_contains "$event_log" "update_runtime_policy_lists" "not-due auto updater should not fetch remote lists"

: >"$event_log"
: >"$TEST_UCI_LOG"
: >"$POLICY_REMOTE_CRON_FILE"
printf '23 * * * * /usr/bin/mihowrt auto-update-policy-lists >/dev/null 2>&1 # mihowrt policy remote auto-update\n' >"$POLICY_REMOTE_CRON_FILE"
TEST_UCI_POLICY_REMOTE_INTERVAL=0
printf 'next_update=0\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
auto_update_output="$(auto_update_policy_remote_lists)"
assert_eq "updated=0" "$auto_update_output" "auto updater should disable itself without fetching when interval becomes zero"
assert_file_not_contains "$event_log" "update_runtime_policy_lists" "zero interval auto updater should not fetch remote lists"
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "zero interval auto updater should remove stale cron entry"
[[ ! -e "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" ]] || fail "zero interval auto updater should remove tmpfs schedule state"

: >"$event_log"
: >"$TEST_UCI_LOG"
: >"$POLICY_REMOTE_CRON_FILE"
printf '23 * * * * /usr/bin/mihowrt auto-update-policy-lists >/dev/null 2>&1 # mihowrt policy remote auto-update\n' >"$POLICY_REMOTE_CRON_FILE"
TEST_UCI_POLICY_REMOTE_INTERVAL=4
printf 'next_update=0\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
TEST_POLICY_UPDATE_RC=0
TEST_POLICY_UPDATED=1
auto_update_output="$(auto_update_policy_remote_lists)"
assert_eq "updated=1" "$auto_update_output" "auto updater should forward changed update result"
assert_file_contains "$event_log" "update_runtime_policy_lists" "due auto updater should fetch remote lists"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "last_result=success" "successful auto update should store tmpfs result"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "reason=" "successful auto update should clear tmpfs failure reason"
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "successful auto update should keep cron entry"

: >"$event_log"
: >"$TEST_UCI_LOG"
printf 'next_update=0\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
TEST_POLICY_UPDATE_RC=1
assert_false "auto updater should fail when remote policy update fails" auto_update_policy_remote_lists >/dev/null
assert_file_contains "$event_log" "update_runtime_policy_lists" "failing auto updater should still attempt due update"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "last_result=failure" "failing auto updater should store tmpfs failure state"
assert_file_contains "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" "reason=remote policy list auto-update failed" "failing auto updater should record failure reason in tmpfs"
assert_file_not_contains "$TEST_UCI_LOG" "-q set" "auto updater should not write UCI state on scheduled runs"

pass "policy remote auto update"
