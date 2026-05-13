#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmpbin/logread" <<'EOF'
#!/usr/bin/env bash
cat <<'LOGS'
Mon Jan  1 00:00:00 2026 daemon.info dnsmasq: startup
Mon Jan  1 00:00:01 2026 daemon.info mihowrt: prepared policy state
Mon Jan  1 00:00:02 2026 daemon.warn mihowrt[321]: warning line
Mon Jan  1 00:00:03 2026 daemon.info unrelated: skip me
Mon Jan  1 00:00:04 2026 daemon.info mihowrt: last line
LOGS
EOF

chmod +x "$tmpbin/logger" "$tmpbin/logread"
export PATH="$tmpbin:$PATH"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/nft.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/route.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-config.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-snapshot.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/runtime-status.sh"

config_load() {
	return 0
}

config_get_bool() {
	case "$3" in
		dns_hijack) printf -v "$1" '%s' "1" ;;
		disable_quic) printf -v "$1" '%s' "0" ;;
	esac
}

config_get() {
	case "$3" in
		route_table_id) printf -v "$1" '%s' "" ;;
		route_rule_priority) printf -v "$1" '%s' "10010" ;;
		policy_mode) printf -v "$1" '%s' "${TEST_POLICY_MODE_SETTING:-direct-first}" ;;
	esac
}

config_list_foreach() {
	"$3" "br-lan"
	"$3" "wg0"
}

default_source_interface() {
	printf 'br-lan\n'
}

count_valid_list_entries() {
	if [[ "$1" == *dst* ]]; then
		printf '2\n'
	else
		printf '3\n'
	fi
}

service_enabled_state() {
	return 0
}

service_running_state() {
	return 0
}

mihomo_ready_state() {
	[ -n "${1:-}" ] || return 1
	[ -n "${2:-}" ] || return 1
	return "${TEST_SERVICE_READY_RC:-0}"
}

dns_backup_exists() {
	return 0
}

dns_backup_valid() {
	return 0
}

dns_persist_backup_exists() {
	return 0
}

dns_persist_backup_valid() {
	return 0
}

policy_route_state_read() {
	ROUTE_TABLE_ID_EFFECTIVE="201"
	ROUTE_RULE_PRIORITY_EFFECTIVE="10010"
	return 0
}

nft_table_exists() {
	return "${TEST_NFT_TABLE_EXISTS_RC:-0}"
}

runtime_live_state_present() {
	return "${TEST_RUNTIME_LIVE_STATE_PRESENT_RC:-0}"
}

runtime_snapshot_exists() {
	return "${TEST_RUNTIME_SNAPSHOT_EXISTS_RC:-1}"
}

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15","external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"./ui","external_ui_name":"zashboard","errors":[]}
EOF
}

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_NFT_TABLE_EXISTS_RC=0
status_output="$(status_json)"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.service_running')" "status_json should expose running service state"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.service_enabled')" "status_json should expose boot-enabled state"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.service_ready')" "status_json should expose service readiness"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.dns_backup_valid')" "status_json should expose dns backup validity"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.dns_recovery_backup_active')" "status_json should expose active dns recovery backup state"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.dns_recovery_backup_valid')" "status_json should expose active dns recovery backup validity"
assert_eq "auto" "$(printf '%s\n' "$status_output" | jq -r '.route_table_id')" "status_json should map empty route table to auto"
assert_eq "10010" "$(printf '%s\n' "$status_output" | jq -r '.route_rule_priority')" "status_json should expose configured route rule priority"
assert_eq "201" "$(printf '%s\n' "$status_output" | jq -r '.route_table_id_effective')" "status_json should expose effective route table id"
assert_eq "2" "$(printf '%s\n' "$status_output" | jq -r '.always_proxy_dst_count')" "status_json should expose destination list count"
assert_eq "wg0" "$(printf '%s\n' "$status_output" | jq -r '.source_network_interfaces[1]')" "status_json should expose source interfaces list"
assert_eq "127.0.0.1#7874" "$(printf '%s\n' "$status_output" | jq -r '.config.mihomo_dns_listen')" "status_json should embed parsed config summary"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.runtime_snapshot_present')" "status_json should report runtime snapshot presence"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.runtime_snapshot_valid')" "status_json should report runtime snapshot validity"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.runtime_safe_reload_ready')" "status_json should report safe reload readiness"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.runtime_matches_desired')" "status_json should report runtime/config parity"
assert_eq "201" "$(printf '%s\n' "$status_output" | jq -r '.active.route_table_id')" "status_json should expose applied runtime route table id"

status_runtime_output="$(status_runtime_state)"
assert_eq "1" "$(printf '%s\n' "$status_runtime_output" | sed -n 's/^runtime_matches_desired=//p')" "status_runtime_state should report desired/runtime parity when snapshot matches"
assert_eq "201" "$(printf '%s\n' "$status_runtime_output" | sed -n 's/^active_route_table_id=//p')" "status_runtime_state should expose applied route table id"

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"policy_mode":"proxy-first","dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":0,"always_proxy_src_count":0,"direct_dst_count":2}
EOF
}

TEST_POLICY_MODE_SETTING=proxy-first
status_output_proxy_first="$(status_json)"
assert_eq "proxy-first" "$(printf '%s\n' "$status_output_proxy_first" | jq -r '.policy_mode')" "status_json should expose proxy-first policy mode"
assert_eq "0" "$(printf '%s\n' "$status_output_proxy_first" | jq -r '.always_proxy_dst_count')" "status_json should disable always-proxy destination count in proxy-first mode"
assert_eq "2" "$(printf '%s\n' "$status_output_proxy_first" | jq -r '.direct_dst_count')" "status_json should count direct destinations in proxy-first mode"
assert_eq "true" "$(printf '%s\n' "$status_output_proxy_first" | jq -r '.runtime_matches_desired')" "status_json should match proxy-first runtime snapshot"
TEST_POLICY_MODE_SETTING=direct-first

logs_output="$(logs_json 2)"
assert_eq "true" "$(printf '%s\n' "$logs_output" | jq -r '.available')" "logs_json should report available logread command"
assert_eq "2" "$(printf '%s\n' "$logs_output" | jq -r '.limit')" "logs_json should preserve limit"
assert_eq "2" "$(printf '%s\n' "$logs_output" | jq -r '.lines | length')" "logs_json should keep only requested number of lines"
assert_eq "Mon Jan  1 00:00:02 2026 daemon.warn mihowrt[321]: warning line" "$(printf '%s\n' "$logs_output" | jq -r '.lines[0]')" "logs_json should keep earlier matching line within limit window"
assert_eq "Mon Jan  1 00:00:04 2026 daemon.info mihowrt: last line" "$(printf '%s\n' "$logs_output" | jq -r '.lines[1]')" "logs_json should keep latest matching line"

runtime_live_state_present() {
	return "${TEST_RUNTIME_LIVE_STATE_PRESENT_RC:-0}"
}

runtime_snapshot_status_json() {
	return 1
}

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=1
TEST_NFT_TABLE_EXISTS_RC=0
status_output_no_snapshot="$(status_json)"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.service_ready')" "status_json should keep service not ready until policy snapshot exists for enabled policy"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.runtime_snapshot_present')" "status_json should report missing runtime snapshot"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.runtime_snapshot_valid')" "status_json should report missing runtime snapshot as invalid"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.runtime_safe_reload_ready')" "status_json should block safe reload when live state lacks snapshot"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.runtime_matches_desired')" "status_json should not claim runtime/config parity without snapshot"
assert_eq "false" "$(printf '%s\n' "$status_output_no_snapshot" | jq -r '.active.present')" "status_json should not invent applied runtime state without snapshot"

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=1
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=1
TEST_NFT_TABLE_EXISTS_RC=0
status_output_no_runtime="$(status_json)"
assert_eq "false" "$(printf '%s\n' "$status_output_no_runtime" | jq -r '.service_ready')" "status_json should keep service not ready when enabled policy markers are missing"
assert_eq "false" "$(printf '%s\n' "$status_output_no_runtime" | jq -r '.runtime_matches_desired')" "status_json should not claim parity when policy should be enabled but runtime is clean"

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":true,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_NFT_TABLE_EXISTS_RC=0
status_runtime_output_drift="$(status_runtime_state)"
assert_eq "0" "$(printf '%s\n' "$status_runtime_output_drift" | sed -n 's/^runtime_matches_desired=//p')" "status_runtime_state should report drift when applied snapshot differs from desired config"
assert_eq "1" "$(printf '%s\n' "$status_runtime_output_drift" | sed -n 's/^service_ready=//p')" "status_runtime_state should expose service readiness"
assert_eq "1" "$(printf '%s\n' "$status_runtime_output_drift" | sed -n 's/^runtime_snapshot_valid=//p')" "status_runtime_state should expose snapshot validity"

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

runtime_snapshot_status_json() {
	printf '%s\n' 'runtime snapshot parse failed' >&2
	return 1
}

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_NFT_TABLE_EXISTS_RC=0
status_output_invalid_snapshot="$(status_json)"
assert_eq "false" "$(printf '%s\n' "$status_output_invalid_snapshot" | jq -r '.service_ready')" "status_json should keep service not ready when runtime snapshot is invalid"
assert_eq "true" "$(printf '%s\n' "$status_output_invalid_snapshot" | jq -r '.runtime_snapshot_present')" "status_json should keep snapshot presence when snapshot files exist but parsing fails"
assert_eq "false" "$(printf '%s\n' "$status_output_invalid_snapshot" | jq -r '.runtime_snapshot_valid')" "status_json should flag invalid runtime snapshot"
assert_eq "false" "$(printf '%s\n' "$status_output_invalid_snapshot" | jq -r '.runtime_matches_desired')" "status_json should not claim parity when snapshot is invalid"
assert_eq "true" "$(printf '%s\n' "$status_output_invalid_snapshot" | jq -r 'any(.errors[]; contains("runtime snapshot parse failed"))')" "status_json should surface invalid runtime snapshot details"

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"","mihomo_dns_listen":"","tproxy_port":"","routing_mark":"","enhanced_mode":"","catch_fakeip":false,"fake_ip_range":"","external_controller":"","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","errors":["config parse failed"]}
EOF
}

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_NFT_TABLE_EXISTS_RC=0
status_output_config_error_ready="$(status_json)"
assert_eq "true" "$(printf '%s\n' "$status_output_config_error_ready" | jq -r '.service_ready')" "status_json should use active runtime ports for readiness when config parsing fails"
assert_eq "true" "$(printf '%s\n' "$status_output_config_error_ready" | jq -r 'any(.errors[]; contains("config parse failed"))')" "status_json should still surface config parse errors"

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15","external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"./ui","external_ui_name":"zashboard","errors":[]}
EOF
}

config_load() {
	return 1
}

runtime_snapshot_status_json() {
	return 1
}

TEST_RUNTIME_SNAPSHOT_EXISTS_RC=1
TEST_NFT_TABLE_EXISTS_RC=0
status_output_no_uci="$(status_json)"
assert_eq "unavailable" "$(printf '%s\n' "$status_output_no_uci" | jq -r '.route_table_id')" "status_json should not pretend route table config exists when UCI load fails"
assert_eq "unavailable" "$(printf '%s\n' "$status_output_no_uci" | jq -r '.route_rule_priority')" "status_json should not pretend route rule config exists when UCI load fails"
assert_eq "0" "$(printf '%s\n' "$status_output_no_uci" | jq -r '.source_network_interfaces | length')" "status_json should not invent source interfaces when UCI load fails"
assert_eq "true" "$(printf '%s\n' "$status_output_no_uci" | jq -r '.service_ready')" "status_json should still expose readiness when Mihomo listeners are healthy"
assert_eq "false" "$(printf '%s\n' "$status_output_no_uci" | jq -r '.runtime_matches_desired')" "status_json should not claim desired/runtime parity when UCI load fails"
assert_eq "true" "$(printf '%s\n' "$status_output_no_uci" | jq -r 'any(.errors[]; contains("Failed to read /etc/config/mihowrt"))')" "status_json should surface UCI load failure"

config_load() {
	return 0
}

runtime_snapshot_status_json() {
	cat <<'EOF'
{"present":true,"enabled":true,"dns_hijack":true,"mihomo_dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","mihomo_tproxy_port":"7894","mihomo_routing_mark":"2","route_table_id":"201","route_rule_priority":"10010","disable_quic":false,"dns_enhanced_mode":"fake-ip","catch_fakeip":true,"fakeip_range":"198.18.0.0/15","source_network_interfaces":["br-lan","wg0"],"always_proxy_dst_count":2,"always_proxy_src_count":3}
EOF
}

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15","external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"./ui","external_ui_name":"zashboard","errors":[]}
EOF
}

TEST_RUNTIME_LIVE_STATE_PRESENT_RC=0
TEST_SERVICE_READY_RC=0
TEST_RUNTIME_SNAPSHOT_EXISTS_RC=0
TEST_NFT_TABLE_EXISTS_RC=1
status_output_missing_nft="$(status_json)"
assert_eq "true" "$(printf '%s\n' "$status_output_missing_nft" | jq -r '.service_ready')" "status_json should keep service ready when valid runtime snapshot already exists"
assert_eq "true" "$(printf '%s\n' "$status_output_missing_nft" | jq -r '.runtime_matches_desired')" "status_json should not treat missing nft probe as runtime drift when snapshot is valid"

pass "diagnostics helpers"
