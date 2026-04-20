#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

PKG_TMP_DIR="$tmpdir/run"
DST_LIST_FILE="$tmpdir/dst.txt"
SRC_LIST_FILE="$tmpdir/src.txt"

log() {
	printf 'log:%s\n' "$*" >>"$event_log"
}

ensure_dir() {
	printf 'ensure_dir:%s\n' "$1" >>"$event_log"
	mkdir -p "$1"
}

policy_route_setup() {
	printf 'policy_route_setup\n' >>"$event_log"
	return "${TEST_POLICY_ROUTE_SETUP_RC:-0}"
}

nft_apply_policy() {
	printf 'nft_apply_policy\n' >>"$event_log"
	return "${TEST_NFT_APPLY_RC:-0}"
}

dns_setup() {
	printf 'dns_setup\n' >>"$event_log"
	return "${TEST_DNS_SETUP_RC:-0}"
}

dns_restore() {
	printf 'dns_restore\n' >>"$event_log"
	return "${TEST_DNS_RESTORE_RC:-0}"
}

nft_remove_policy() {
	printf 'nft_remove_policy\n' >>"$event_log"
	return "${TEST_NFT_REMOVE_RC:-0}"
}

policy_route_cleanup() {
	printf 'policy_route_cleanup\n' >>"$event_log"
	return "${TEST_POLICY_ROUTE_CLEANUP_RC:-0}"
}

: > "$event_log"
TEST_NFT_APPLY_RC=0
TEST_DNS_SETUP_RC=0
apply_runtime_state
assert_file_contains "$event_log" "ensure_dir:$PKG_TMP_DIR" "apply_runtime_state should ensure runtime dir exists"
assert_file_contains "$event_log" "policy_route_setup" "apply_runtime_state should set up route state"
assert_file_contains "$event_log" "nft_apply_policy" "apply_runtime_state should apply nftables policy"
assert_file_contains "$event_log" "dns_setup" "apply_runtime_state should set up DNS hijack"
assert_file_contains "$event_log" "log:Prepared direct-first policy state" "apply_runtime_state should log success"

nft_apply_policy() {
	printf 'nft_apply_policy\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "apply_runtime_state should fail when nft policy application fails" apply_runtime_state
assert_file_contains "$event_log" "policy_route_cleanup" "apply_runtime_state should tear down route state when nft apply fails"
assert_file_not_contains "$event_log" "dns_restore" "apply_runtime_state should not restore DNS when nft apply fails before DNS setup"

nft_apply_policy() {
	printf 'nft_apply_policy\n' >>"$event_log"
	return 0
}

dns_setup() {
	printf 'dns_setup\n' >>"$event_log"
	return 1
}

: > "$event_log"
assert_false "apply_runtime_state should fail when dns setup fails" apply_runtime_state
assert_file_contains "$event_log" "dns_restore" "apply_runtime_state should restore DNS after DNS setup failure"
assert_file_contains "$event_log" "nft_remove_policy" "apply_runtime_state should remove nft policy after DNS setup failure"
assert_file_contains "$event_log" "policy_route_cleanup" "apply_runtime_state should clean route state after DNS setup failure"

dns_restore() {
	printf 'dns_restore\n' >>"$event_log"
	return 1
}

nft_remove_policy() {
	printf 'nft_remove_policy\n' >>"$event_log"
	return 1
}

policy_route_cleanup() {
	printf 'policy_route_cleanup\n' >>"$event_log"
	return 1
}

: > "$event_log"
cleanup_runtime_state
assert_file_contains "$event_log" "dns_restore" "cleanup_runtime_state should try DNS restore"
assert_file_contains "$event_log" "nft_remove_policy" "cleanup_runtime_state should try nft cleanup"
assert_file_contains "$event_log" "policy_route_cleanup" "cleanup_runtime_state should try route cleanup"
assert_file_contains "$event_log" "log:Cleaned up direct-first policy state" "cleanup_runtime_state should log cleanup success"

cleanup_runtime_state() {
	printf 'cleanup_runtime_state\n' >>"$event_log"
	return 0
}

prepare_runtime_state() {
	printf 'prepare_runtime_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
reload_runtime_state
assert_file_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should clean old state first"
assert_file_contains "$event_log" "prepare_runtime_state" "reload_runtime_state should prepare fresh state after cleanup"

dns_recovery_needed() {
	return "${TEST_DNS_RECOVERY_NEEDED_RC:-1}"
}

cleanup_runtime_state() {
	printf 'cleanup_runtime_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_DNS_RECOVERY_NEEDED_RC=1
recover_runtime_state
[[ ! -s "$event_log" ]] || fail "recover_runtime_state should stay idle when no DNS recovery is needed"

: > "$event_log"
TEST_DNS_RECOVERY_NEEDED_RC=0
recover_runtime_state
assert_file_contains "$event_log" "log:Recovering runtime state after unclean shutdown" "recover_runtime_state should log crash recovery"
assert_file_contains "$event_log" "cleanup_runtime_state" "recover_runtime_state should clean runtime state after crash"

load_runtime_config() {
	ENABLED=1
	MIHOMO_DNS_PORT="7874"
	MIHOMO_DNS_LISTEN="127.0.0.1#7874"
	DNS_HIJACK=1
	MIHOMO_TPROXY_PORT="7894"
	MIHOMO_ROUTING_MARK="2"
	MIHOMO_ROUTE_TABLE_ID=""
	MIHOMO_ROUTE_RULE_PRIORITY=""
	DISABLE_QUIC=0
	DNS_ENHANCED_MODE="fake-ip"
	CATCH_FAKEIP=1
	FAKEIP_RANGE="198.18.0.0/15"
	SOURCE_INTERFACES="br-lan wg0"
	return 0
}

count_valid_list_entries() {
	if [[ "$1" == "$DST_LIST_FILE" ]]; then
		printf '2\n'
	else
		printf '3\n'
	fi
}

status_output="$(status_runtime_state)"
assert_eq "enabled=1" "$(printf '%s\n' "$status_output" | sed -n '1p')" "status_runtime_state should report enabled flag"
assert_eq "route_table_id=auto" "$(printf '%s\n' "$status_output" | grep '^route_table_id=')" "status_runtime_state should show auto route table when unset"
assert_eq "always_proxy_dst_count=2" "$(printf '%s\n' "$status_output" | grep '^always_proxy_dst_count=')" "status_runtime_state should report destination list count"
assert_eq "always_proxy_src_count=3" "$(printf '%s\n' "$status_output" | grep '^always_proxy_src_count=')" "status_runtime_state should report source list count"

pass "policy runtime orchestration"
