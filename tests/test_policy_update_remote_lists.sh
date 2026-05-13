#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"
PKG_STATE_DIR="$tmpdir/state"
PKG_TMP_DIR="$tmpdir/run"
DST_LIST_FILE="$tmpdir/source-dst.txt"
SRC_LIST_FILE="$tmpdir/source-src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/source-direct.txt"
mkdir -p "$PKG_STATE_DIR" "$PKG_TMP_DIR"
: > "$DST_LIST_FILE"
: > "$SRC_LIST_FILE"
: > "$DIRECT_DST_LIST_FILE"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

log() {
	printf 'log:%s\n' "$*" >>"$event_log"
}

warn() {
	printf 'warn:%s\n' "$*" >>"$event_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$event_log"
}

require_command() {
	return 0
}

ensure_dir() {
	printf 'ensure_dir:%s\n' "$1" >>"$event_log"
	mkdir -p "$1"
}

runtime_snapshot_valid() {
	printf 'runtime_snapshot_valid\n' >>"$event_log"
	return "${TEST_RUNTIME_SNAPSHOT_VALID_RC:-0}"
}

runtime_live_state_present() {
	printf 'runtime_live_state_present\n' >>"$event_log"
	return "${TEST_RUNTIME_LIVE_STATE_PRESENT_RC:-0}"
}

load_runtime_config() {
	printf 'load_runtime_config\n' >>"$event_log"
	POLICY_MODE="${TEST_POLICY_MODE:-direct-first}"
	DNS_HIJACK=1
	MIHOMO_DNS_PORT="7874"
	MIHOMO_DNS_LISTEN="127.0.0.1#7874"
	MIHOMO_TPROXY_PORT="7894"
	MIHOMO_ROUTING_MARK="2"
	MIHOMO_ROUTE_TABLE_ID=""
	MIHOMO_ROUTE_RULE_PRIORITY=""
	DISABLE_QUIC=0
	DNS_ENHANCED_MODE="fake-ip"
	CATCH_FAKEIP=1
	FAKEIP_RANGE="198.18.0.0/15"
	SOURCE_INTERFACES="br-lan"
	return "${TEST_LOAD_RUNTIME_RC:-0}"
}

validate_runtime_config() {
	printf 'validate_runtime_config\n' >>"$event_log"
	return "${TEST_VALIDATE_RUNTIME_RC:-0}"
}

runtime_snapshot_mihomo_config_matches_current() {
	printf 'runtime_snapshot_mihomo_config_matches_current\n' >>"$event_log"
	return "${TEST_MIHOMO_MATCH_RC:-0}"
}

policy_route_state_read() {
	TEST_ROUTE_STATE_READ_COUNT="${TEST_ROUTE_STATE_READ_COUNT:-0}"
	TEST_ROUTE_STATE_READ_COUNT=$((TEST_ROUTE_STATE_READ_COUNT + 1))
	if [ "$TEST_ROUTE_STATE_READ_COUNT" -eq 1 ]; then
		ROUTE_TABLE_ID_EFFECTIVE="${TEST_OLD_ROUTE_TABLE_ID:-200}"
		ROUTE_RULE_PRIORITY_EFFECTIVE="${TEST_OLD_ROUTE_RULE_PRIORITY:-10000}"
	else
		ROUTE_TABLE_ID_EFFECTIVE="${TEST_NEW_ROUTE_TABLE_ID:-${TEST_OLD_ROUTE_TABLE_ID:-200}}"
		ROUTE_RULE_PRIORITY_EFFECTIVE="${TEST_NEW_ROUTE_RULE_PRIORITY:-${TEST_OLD_ROUTE_RULE_PRIORITY:-10000}}"
	fi
	printf 'policy_route_state_read:%s:%s\n' "$ROUTE_TABLE_ID_EFFECTIVE" "$ROUTE_RULE_PRIORITY_EFFECTIVE" >>"$event_log"
	return 0
}

policy_resolve_runtime_lists() {
	printf 'policy_resolve_runtime_lists\n' >>"$event_log"
	[ "${TEST_RESOLVE_RUNTIME_LISTS_RC:-0}" -eq 0 ] || return "${TEST_RESOLVE_RUNTIME_LISTS_RC:-1}"
	POLICY_DST_LIST_FILE="$tmpdir/effective-dst.txt"
	POLICY_SRC_LIST_FILE="$tmpdir/effective-src.txt"
	POLICY_DIRECT_DST_LIST_FILE="$tmpdir/effective-direct.txt"
	POLICY_EFFECTIVE_LIST_FILES="$POLICY_DST_LIST_FILE $POLICY_SRC_LIST_FILE $POLICY_DIRECT_DST_LIST_FILE"
	printf '%s\n' "${TEST_EFFECTIVE_DST:-1.1.1.1}" > "$POLICY_DST_LIST_FILE"
	printf '%s\n' "${TEST_EFFECTIVE_SRC:-:53}" > "$POLICY_SRC_LIST_FILE"
	printf '%s\n' "${TEST_EFFECTIVE_DIRECT:-8.8.8.8}" > "$POLICY_DIRECT_DST_LIST_FILE"
}

policy_clear_runtime_list_overrides() {
	printf 'policy_clear_runtime_list_overrides\n' >>"$event_log"
	# shellcheck disable=SC2086
	rm -f ${POLICY_EFFECTIVE_LIST_FILES:-}
	unset POLICY_DST_LIST_FILE POLICY_SRC_LIST_FILE POLICY_DIRECT_DST_LIST_FILE POLICY_EFFECTIVE_LIST_FILES
}

nft_apply_policy() {
	printf 'nft_apply_policy\n' >>"$event_log"
	return "${TEST_NFT_APPLY_RC:-0}"
}

runtime_snapshot_save() {
	printf 'runtime_snapshot_save\n' >>"$event_log"
	return "${TEST_SNAPSHOT_SAVE_RC:-0}"
}

runtime_snapshot_restore() {
	printf 'runtime_snapshot_restore\n' >>"$event_log"
	return "${TEST_SNAPSHOT_RESTORE_RC:-0}"
}

dns_restore() {
	printf 'dns_restore\n' >>"$event_log"
	return 0
}

nft_remove_policy() {
	printf 'nft_remove_policy\n' >>"$event_log"
	return 0
}

policy_route_cleanup() {
	printf 'policy_route_cleanup\n' >>"$event_log"
	return 0
}

policy_route_teardown_ids() {
	printf 'policy_route_teardown_ids:%s:%s\n' "$1" "$2" >>"$event_log"
	return 0
}

write_snapshot_lists() {
	printf '%s\n' "${1:-1.1.1.1}" > "$(runtime_snapshot_dst_file)"
	printf '%s\n' "${2:-:53}" > "$(runtime_snapshot_src_file)"
	printf '%s\n' "${3:-8.8.8.8}" > "$(runtime_snapshot_direct_file)"
	cat > "$(runtime_snapshot_file)" <<EOF
{"enabled":true,"policy_mode":"${TEST_SNAPSHOT_POLICY_MODE:-${TEST_POLICY_MODE:-direct-first}}","dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id_effective":"${TEST_OLD_ROUTE_TABLE_ID:-200}","route_rule_priority_effective":"${TEST_OLD_ROUTE_RULE_PRIORITY:-10000}","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan"]}
EOF
}

: > "$event_log"
TEST_POLICY_MODE="direct-first"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_EFFECTIVE_DST="1.1.1.1"
TEST_EFFECTIVE_SRC=":53"
TEST_ROUTE_STATE_READ_COUNT=0
update_output="$(update_runtime_policy_lists)"
assert_eq "updated=0" "$update_output" "update_runtime_policy_lists should report unchanged lists"
assert_file_contains "$event_log" "policy_resolve_runtime_lists" "unchanged update should fetch and resolve remote lists"
assert_file_contains "$event_log" "runtime_snapshot_save" "unchanged update should refresh snapshot metadata"
assert_file_not_contains "$event_log" "nft_apply_policy" "unchanged update should not edit nft policy"
assert_file_contains "$event_log" "log:Remote policy lists unchanged; nft policy left untouched" "unchanged update should log nft no-op"

: > "$event_log"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_EFFECTIVE_DST="2.2.2.2"
TEST_EFFECTIVE_SRC=":53"
TEST_ROUTE_STATE_READ_COUNT=0
update_output="$(update_runtime_policy_lists)"
assert_eq "updated=1" "$update_output" "update_runtime_policy_lists should report changed lists"
assert_file_contains "$event_log" "nft_apply_policy" "changed update should apply nft policy"
assert_file_not_contains "$event_log" "policy_route_setup" "changed update should not reinstall policy routes"
assert_file_not_contains "$event_log" "dns_setup" "changed update should not reconfigure DNS"
assert_file_contains "$event_log" "runtime_snapshot_save" "changed update should persist new snapshot"
assert_file_contains "$event_log" "log:Updated remote policy lists and refreshed direct-first nft policy" "changed update should log nft refresh"

: > "$event_log"
TEST_EFFECTIVE_DST="1.1.1.1"
TEST_EFFECTIVE_SRC=":53"
TEST_EFFECTIVE_DIRECT="9.9.9.9"
TEST_POLICY_MODE="proxy-first"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_ROUTE_STATE_READ_COUNT=0
update_output="$(update_runtime_policy_lists)"
assert_eq "updated=1" "$update_output" "proxy-first update should compare direct destination list"
assert_file_contains "$event_log" "nft_apply_policy" "proxy-first direct list change should apply nft policy"
TEST_POLICY_MODE="direct-first"

: > "$event_log"
TEST_SNAPSHOT_POLICY_MODE="direct-first"
TEST_POLICY_MODE="proxy-first"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_ROUTE_STATE_READ_COUNT=0
assert_false "update_runtime_policy_lists should fail when non-list policy config drifted" update_runtime_policy_lists >/dev/null
assert_file_contains "$event_log" "err:Policy config changed since runtime snapshot; apply policy settings before updating remote lists" "policy config drift should be reported"
assert_file_not_contains "$event_log" "policy_resolve_runtime_lists" "policy config drift should not fetch remote lists"
unset TEST_SNAPSHOT_POLICY_MODE
TEST_POLICY_MODE="direct-first"

: > "$event_log"
TEST_RESOLVE_RUNTIME_LISTS_RC=1
TEST_ROUTE_STATE_READ_COUNT=0
assert_false "update_runtime_policy_lists should fail when remote list preparation fails" update_runtime_policy_lists >/dev/null
assert_file_contains "$event_log" "err:Failed to prepare updated policy lists" "resolve failure should be reported"
assert_file_not_contains "$event_log" "nft_apply_policy" "resolve failure should not edit nft policy"
assert_file_not_contains "$event_log" "runtime_snapshot_restore" "resolve failure should not rollback unchanged runtime"
TEST_RESOLVE_RUNTIME_LISTS_RC=0

: > "$event_log"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_EFFECTIVE_DST="2.2.2.2"
TEST_EFFECTIVE_SRC=":53"
TEST_NFT_APPLY_RC=1
TEST_ROUTE_STATE_READ_COUNT=0
assert_false "update_runtime_policy_lists should restore snapshot when changed apply fails" update_runtime_policy_lists >/dev/null
assert_file_contains "$event_log" "nft_apply_policy" "changed apply failure should happen after diff detection"
assert_file_contains "$event_log" "runtime_snapshot_restore" "changed apply failure should rollback previous runtime"
TEST_NFT_APPLY_RC=0

: > "$event_log"
write_snapshot_lists "1.1.1.1" ":53" "8.8.8.8"
TEST_OLD_ROUTE_TABLE_ID=201
TEST_EFFECTIVE_DST="2.2.2.2"
TEST_EFFECTIVE_SRC=":53"
TEST_ROUTE_STATE_READ_COUNT=0
assert_false "update_runtime_policy_lists should fail when live route state differs from snapshot" update_runtime_policy_lists >/dev/null
assert_file_contains "$event_log" "err:Policy route state changed since runtime snapshot; reload or restart MihoWRT before updating remote lists" "route drift should be reported before fetching lists"
assert_file_not_contains "$event_log" "policy_resolve_runtime_lists" "route drift should not fetch remote lists"
unset TEST_OLD_ROUTE_TABLE_ID

: > "$event_log"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
assert_false "update_runtime_policy_lists should fail when runtime is not active" update_runtime_policy_lists >/dev/null
assert_file_contains "$event_log" "err:Runtime policy state is not active; cannot update remote policy lists" "inactive runtime should be reported"
assert_file_not_contains "$event_log" "policy_resolve_runtime_lists" "inactive runtime should not fetch remote lists"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0

pass "policy remote list update"
