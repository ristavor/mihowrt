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
chmod +x "$tmpbin/logger"
export PATH="$tmpbin:$PATH"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"

event_log="$tmpdir/events.log"
POLICY_REMOTE_CRON_FILE="$tmpdir/root.cron"
POLICY_REMOTE_AUTO_UPDATE_STATE_FILE="$tmpdir/legacy-policy-remote-auto.state"
POLICY_REMOTE_URL_STATE_DIR="$tmpdir/url-state"
DST_LIST_FILE="$tmpdir/always_proxy_dst.txt"
SRC_LIST_FILE="$tmpdir/always_proxy_src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/direct_dst.txt"
: >"$DST_LIST_FILE"
: >"$SRC_LIST_FILE"
: >"$DIRECT_DST_LIST_FILE"

update_runtime_policy_lists() {
	printf 'update_runtime_policy_lists auto=%s\n' "${POLICY_REMOTE_AUTO_MODE:-0}" >>"$event_log"
	[ "${TEST_POLICY_UPDATE_RC:-0}" -eq 0 ] || return "${TEST_POLICY_UPDATE_RC:-1}"
	printf 'updated=%s\n' "${TEST_POLICY_UPDATED:-1}"
}

assert_true "zero per-URL interval should be valid" policy_remote_update_interval_valid "0"
assert_true "positive per-URL interval should be valid" policy_remote_update_interval_valid "24"
assert_false "too large per-URL interval should be invalid" policy_remote_update_interval_valid "8761"
assert_eq "https://example.com/list.txt" "$(policy_remote_list_base 'https://example.com/list.txt | 12')" "per-URL parser should strip update interval"
assert_eq "12" "$(policy_remote_list_interval 'https://example.com/list.txt | 12')" "per-URL parser should return update interval"
assert_eq "0" "$(policy_remote_list_interval 'https://example.com/list.txt | 0')" "zero should disable one URL schedule"
assert_false "invalid per-URL interval should fail" policy_remote_list_interval 'https://example.com/list.txt | nope' >/dev/null

rm -f "$POLICY_REMOTE_CRON_FILE"
policy_remote_sync_auto_update_cron 0
[[ ! -e "$POLICY_REMOTE_CRON_FILE" ]] || fail "disabled cron sync should not create an absent crontab"
printf '0 0 * * * echo keep\n23 * * * * /usr/bin/mihowrt auto-update-policy-lists >/dev/null 2>&1 # mihowrt policy remote auto-update\n' >"$POLICY_REMOTE_CRON_FILE"
policy_remote_sync_auto_update_cron 0
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "echo keep" "cron sync should preserve unrelated entries"
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "cron sync should remove the MihoWRT task"
policy_remote_sync_auto_update_cron 1
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "cron sync should enable hourly schedule checks"
policy_cron_inode="$(stat -c %i "$POLICY_REMOTE_CRON_FILE")"
policy_remote_sync_auto_update_cron 1
assert_eq "$policy_cron_inode" "$(stat -c %i "$POLICY_REMOTE_CRON_FILE")" "unchanged cron sync should avoid rewrites"

printf 'next_update=123\n' >"$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE"
: >"$DST_LIST_FILE"
: >"$POLICY_REMOTE_CRON_FILE"
policy_remote_refresh_auto_update_state
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "no scheduled URLs should disable cron"
[[ ! -e "$POLICY_REMOTE_AUTO_UPDATE_STATE_FILE" ]] || fail "refresh should remove obsolete global state"

printf 'https://example.com/a.txt | 6\n' >"$DST_LIST_FILE"
policy_remote_refresh_auto_update_state
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "a positive URL interval should enable cron"
printf 'https://example.com/a.txt | 0\n' >"$DST_LIST_FILE"
policy_remote_refresh_auto_update_state
assert_file_not_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "a zero URL interval should disable cron"
printf 'https://example.com/direct.txt | 24\n' >"$DIRECT_DST_LIST_FILE"
policy_remote_refresh_auto_update_state
assert_file_contains "$POLICY_REMOTE_CRON_FILE" "auto-update-policy-lists" "any policy list may enable cron"

policy_remote_now_epoch() { printf '1000\n'; }
source_key='https://example.com/a.txt;'
assert_true "a URL without state should be due" policy_remote_url_due "$source_key" 6
policy_remote_url_mark_success "$source_key" 6
assert_eq "6" "$(policy_remote_url_state_value "$source_key" interval)" "per-URL state should retain its interval"
assert_eq "22600" "$(policy_remote_url_state_value "$source_key" next_update)" "per-URL state should retain its next update"
assert_false "fresh URL state should not be due" policy_remote_url_due "$source_key" 6
policy_remote_now_epoch() { printf '22600\n'; }
assert_true "URL should become due at its own deadline" policy_remote_url_due "$source_key" 6
policy_remote_url_mark_success "$source_key" 0
[[ ! -e "$(policy_remote_url_state_file "$source_key")" ]] || fail "disabling a URL should clear its schedule state"

: >"$DST_LIST_FILE"
: >"$SRC_LIST_FILE"
: >"$DIRECT_DST_LIST_FILE"
: >"$event_log"
auto_update_output="$(auto_update_policy_remote_lists)"
assert_eq "updated=0" "$auto_update_output" "auto updater should no-op without scheduled URLs"
assert_file_not_contains "$event_log" "update_runtime_policy_lists" "disabled auto updater should not resolve lists"

printf 'https://example.com/a.txt | 4\n' >"$DST_LIST_FILE"
: >"$event_log"
TEST_POLICY_UPDATE_RC=0
TEST_POLICY_UPDATED=1
auto_update_output="$(auto_update_policy_remote_lists)"
assert_eq "updated=1" "$auto_update_output" "auto updater should forward the policy update result"
assert_file_contains "$event_log" "update_runtime_policy_lists auto=1" "auto updater should enable per-URL due checks"
[[ -z "${POLICY_REMOTE_AUTO_MODE+x}" ]] || fail "auto updater should clear its mode after success"

: >"$event_log"
TEST_POLICY_UPDATE_RC=1
assert_false "auto updater should forward a failed list update" auto_update_policy_remote_lists >/dev/null
assert_file_contains "$event_log" "update_runtime_policy_lists auto=1" "failing auto updater should still attempt list resolution"
[[ -z "${POLICY_REMOTE_AUTO_MODE+x}" ]] || fail "auto updater should clear its mode after failure"

pass "policy remote auto update"
