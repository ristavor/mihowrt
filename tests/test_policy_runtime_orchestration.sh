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

warn() {
	printf 'warn:%s\n' "$*" >>"$event_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$event_log"
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

runtime_snapshot_save() {
	printf 'runtime_snapshot_save\n' >>"$event_log"
	return "${TEST_RUNTIME_SNAPSHOT_SAVE_RC:-0}"
}

runtime_snapshot_clear() {
	printf 'runtime_snapshot_clear\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_NFT_APPLY_RC=0
TEST_DNS_SETUP_RC=0
TEST_RUNTIME_SNAPSHOT_SAVE_RC=0
apply_runtime_state
assert_file_contains "$event_log" "ensure_dir:$PKG_TMP_DIR" "apply_runtime_state should ensure runtime dir exists"
assert_file_contains "$event_log" "policy_route_setup" "apply_runtime_state should set up route state"
assert_file_contains "$event_log" "nft_apply_policy" "apply_runtime_state should apply nftables policy"
assert_file_contains "$event_log" "dns_setup" "apply_runtime_state should set up DNS hijack"
assert_file_contains "$event_log" "runtime_snapshot_save" "apply_runtime_state should persist runtime snapshot after success"
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

dns_setup() {
	printf 'dns_setup\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_RUNTIME_SNAPSHOT_SAVE_RC=1
assert_false "apply_runtime_state should fail when runtime snapshot persistence fails" apply_runtime_state
assert_file_contains "$event_log" "runtime_snapshot_save" "apply_runtime_state should attempt to persist runtime snapshot"
assert_file_contains "$event_log" "dns_restore" "apply_runtime_state should restore DNS after snapshot persistence failure"
assert_file_contains "$event_log" "nft_remove_policy" "apply_runtime_state should remove nft policy after snapshot persistence failure"
assert_file_contains "$event_log" "policy_route_cleanup" "apply_runtime_state should clean route state after snapshot persistence failure"
assert_file_not_contains "$event_log" "runtime_snapshot_clear" "apply_runtime_state should preserve previous runtime snapshot after snapshot failure"
assert_file_contains "$event_log" "err:Failed to persist runtime snapshot" "apply_runtime_state should report snapshot persistence failure"
TEST_RUNTIME_SNAPSHOT_SAVE_RC=0

: > "$event_log"
assert_false "cleanup_runtime_state should fail when any teardown step fails" cleanup_runtime_state
assert_file_contains "$event_log" "dns_restore" "cleanup_runtime_state should try DNS restore"
assert_file_contains "$event_log" "nft_remove_policy" "cleanup_runtime_state should try nft cleanup"
assert_file_contains "$event_log" "policy_route_cleanup" "cleanup_runtime_state should try route cleanup"
assert_file_contains "$event_log" "runtime_snapshot_clear" "cleanup_runtime_state should clear runtime snapshot"
assert_file_contains "$event_log" "err:Failed to restore dnsmasq state during cleanup" "cleanup_runtime_state should report dns cleanup failure"
assert_file_contains "$event_log" "err:Failed to remove nft policy during cleanup" "cleanup_runtime_state should report nft cleanup failure"
assert_file_contains "$event_log" "err:Failed to remove policy routing during cleanup" "cleanup_runtime_state should report route cleanup failure"
assert_file_contains "$event_log" "err:Direct-first policy cleanup incomplete" "cleanup_runtime_state should report partial cleanup"

cleanup_runtime_state() {
	printf 'cleanup_runtime_state\n' >>"$event_log"
	return 0
}

load_runtime_config() {
	printf 'load_runtime_config\n' >>"$event_log"
	ENABLED="${TEST_ENABLED:-1}"
	return "${TEST_LOAD_RUNTIME_RC:-0}"
}

validate_runtime_config() {
	printf 'validate_runtime_config\n' >>"$event_log"
	return "${TEST_VALIDATE_RUNTIME_RC:-0}"
}

apply_runtime_state() {
	printf 'apply_runtime_state\n' >>"$event_log"
	return "${TEST_APPLY_RUNTIME_RC:-0}"
}

runtime_snapshot_exists() {
	return "${TEST_RUNTIME_SNAPSHOT_EXISTS_RC:-1}"
}

runtime_snapshot_valid() {
	return "${TEST_RUNTIME_SNAPSHOT_VALID_RC:-${TEST_RUNTIME_SNAPSHOT_EXISTS_RC:-1}}"
}

runtime_live_state_present() {
	return "${TEST_RUNTIME_LIVE_STATE_PRESENT_RC:-1}"
}

runtime_snapshot_restore() {
	printf 'runtime_snapshot_restore\n' >>"$event_log"
	return "${TEST_RUNTIME_SNAPSHOT_RESTORE_RC:-0}"
}

policy_route_teardown_ids() {
	printf 'policy_route_teardown_ids:%s:%s\n' "$1" "$2" >>"$event_log"
}

policy_route_state_read() {
	if [ "${TEST_ROUTE_STATE_SEQUENCE:-single}" = "reload-success" ]; then
		TEST_ROUTE_STATE_READ_COUNT="${TEST_ROUTE_STATE_READ_COUNT:-0}"
		TEST_ROUTE_STATE_READ_COUNT=$((TEST_ROUTE_STATE_READ_COUNT + 1))
		case "$TEST_ROUTE_STATE_READ_COUNT" in
			1)
				ROUTE_TABLE_ID_EFFECTIVE="200"
				ROUTE_RULE_PRIORITY_EFFECTIVE="10000"
				;;
			2)
				ROUTE_TABLE_ID_EFFECTIVE="201"
				ROUTE_RULE_PRIORITY_EFFECTIVE="10001"
				;;
			*)
				return 1
				;;
		esac
		return 0
	fi

	return 1
}

: > "$event_log"
TEST_ENABLED=1
TEST_LOAD_RUNTIME_RC=0
TEST_VALIDATE_RUNTIME_RC=0
TEST_APPLY_RUNTIME_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
TEST_RUNTIME_SNAPSHOT_RESTORE_RC=0
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_ROUTE_STATE_SEQUENCE="reload-success"
TEST_ROUTE_STATE_READ_COUNT=0
reload_runtime_state
assert_file_contains "$event_log" "load_runtime_config" "reload_runtime_state should load runtime config before changes"
assert_file_contains "$event_log" "validate_runtime_config" "reload_runtime_state should validate runtime config before teardown"
assert_file_contains "$event_log" "apply_runtime_state" "reload_runtime_state should apply new runtime state when enabled"
assert_file_contains "$event_log" "policy_route_teardown_ids:200:10000" "reload_runtime_state should remove previous route ids after successful apply"
assert_file_contains "$event_log" "log:Reloaded direct-first policy state" "reload_runtime_state should log successful safer reload"
assert_file_not_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should not tear down live state before apply when snapshot exists"

: > "$event_log"
TEST_ENABLED=0
TEST_ROUTE_STATE_SEQUENCE="single"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
reload_runtime_state
assert_file_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should clean runtime state when policy layer is disabled"
assert_file_contains "$event_log" "log:Policy layer disabled; runtime state left clean" "reload_runtime_state should log disabled cleanup path"
assert_file_not_contains "$event_log" "apply_runtime_state" "reload_runtime_state should skip runtime apply when policy layer is disabled"

: > "$event_log"
TEST_ENABLED=1
TEST_VALIDATE_RUNTIME_RC=1
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
assert_false "reload_runtime_state should fail validation before teardown" reload_runtime_state
assert_file_contains "$event_log" "validate_runtime_config" "reload_runtime_state should validate before returning failure"
assert_file_not_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should not tear down live state when validation fails"
TEST_VALIDATE_RUNTIME_RC=0

: > "$event_log"
TEST_ENABLED=1
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=0
TEST_APPLY_RUNTIME_RC=1
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
assert_false "reload_runtime_state should restore previous runtime state when new apply fails" reload_runtime_state
assert_file_contains "$event_log" "apply_runtime_state" "reload_runtime_state should attempt live apply before rollback"
assert_file_contains "$event_log" "runtime_snapshot_restore" "reload_runtime_state should restore previous runtime snapshot on apply failure"
assert_file_contains "$event_log" "err:Failed to apply updated policy; restoring previous runtime state" "reload_runtime_state should log rollback start"
assert_file_not_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should avoid full cleanup before rollback"
TEST_APPLY_RUNTIME_RC=0

: > "$event_log"
TEST_ENABLED=1
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=1
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
reload_runtime_state
assert_file_contains "$event_log" "warn:Runtime snapshot unavailable; applying policy from clean state" "reload_runtime_state should warn when applying without saved snapshot but no live state exists"
assert_file_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should fall back to legacy cleanup path without snapshot"
assert_file_contains "$event_log" "apply_runtime_state" "reload_runtime_state should still apply runtime state after legacy cleanup"

: > "$event_log"
TEST_ENABLED=1
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=1
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
assert_false "reload_runtime_state should refuse in-place reload when live state exists without snapshot" reload_runtime_state
assert_file_contains "$event_log" "err:Runtime snapshot unavailable; refusing in-place reload while live policy state exists" "reload_runtime_state should report blocked reload without snapshot"
assert_file_not_contains "$event_log" "cleanup_runtime_state" "blocked reload should not tear down live state"
assert_file_not_contains "$event_log" "apply_runtime_state" "blocked reload should not apply new state"

: > "$event_log"
TEST_ENABLED=1
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
reload_runtime_state
assert_file_contains "$event_log" "warn:Runtime snapshot invalid; applying policy from clean state" "reload_runtime_state should clean-apply when invalid snapshot has no live runtime"
assert_file_contains "$event_log" "cleanup_runtime_state" "reload_runtime_state should clean stale state before clean apply when invalid snapshot has no live runtime"
assert_file_contains "$event_log" "apply_runtime_state" "reload_runtime_state should apply runtime after invalid snapshot cleanup"

: > "$event_log"
TEST_ENABLED=1
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_RUNTIME_SNAPSHOT_VALID_RC=1
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
assert_false "reload_runtime_state should refuse in-place reload when snapshot is invalid and live state exists" reload_runtime_state
assert_file_contains "$event_log" "err:Runtime snapshot invalid; refusing in-place reload while live policy state exists" "reload_runtime_state should report blocked reload when saved snapshot is invalid"
assert_file_not_contains "$event_log" "cleanup_runtime_state" "blocked invalid-snapshot reload should not tear down live state"
assert_file_not_contains "$event_log" "apply_runtime_state" "blocked invalid-snapshot reload should not apply new state"

cleanup_runtime_state() {
	printf 'cleanup_runtime_state\n' >>"$event_log"
	return 0
}

: > "$event_log"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
recover_runtime_state
[[ ! -s "$event_log" ]] || fail "recover_runtime_state should stay idle when runtime state is already clean"

: > "$event_log"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
recover_runtime_state
assert_file_contains "$event_log" "log:Recovering runtime state after unclean shutdown" "recover_runtime_state should log crash recovery"
assert_file_contains "$event_log" "cleanup_runtime_state" "recover_runtime_state should clean live runtime state after crash even without DNS backup"

: > "$event_log"
TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
recover_runtime_state
assert_file_contains "$event_log" "log:Recovering runtime state after unclean shutdown" "recover_runtime_state should still log crash recovery when DNS backup survives"
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

require_command() {
	return 0
}

config_load() {
	return 0
}

config_get_bool() {
	case "$3" in
		enabled) printf -v "$1" '%s' "1" ;;
		dns_hijack) printf -v "$1" '%s' "1" ;;
		disable_quic) printf -v "$1" '%s' "0" ;;
	esac
}

config_get() {
	case "$3" in
		route_table_id) printf -v "$1" '%s' "" ;;
		route_rule_priority) printf -v "$1" '%s' "" ;;
	esac
}

config_list_foreach() {
	"$3" "br-lan"
	"$3" "wg0"
}

default_source_interface() {
	printf 'br-lan\n'
}

service_enabled_state() {
	return 1
}

service_running_state() {
	return 1
}

dns_backup_exists() {
	return 1
}

dns_backup_valid() {
	return 1
}

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15","external_controller":"","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","errors":[]}
EOF
}

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

status_output="$(status_runtime_state)"
assert_eq "enabled=1" "$(printf '%s\n' "$status_output" | sed -n '1p')" "status_runtime_state should report enabled flag"
assert_eq "route_table_id=auto" "$(printf '%s\n' "$status_output" | grep '^route_table_id=')" "status_runtime_state should show auto route table when unset"
assert_eq "always_proxy_dst_count=2" "$(printf '%s\n' "$status_output" | grep '^always_proxy_dst_count=')" "status_runtime_state should report destination list count"
assert_eq "always_proxy_src_count=3" "$(printf '%s\n' "$status_output" | grep '^always_proxy_src_count=')" "status_runtime_state should report source list count"

pass "policy runtime orchestration"
