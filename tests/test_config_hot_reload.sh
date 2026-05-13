#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"
CLASH_CONFIG="$tmpdir/config.yaml"
SERVICE_PID_FILE="$tmpdir/mihomo.pid"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/config-io.sh"

old_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json="$old_json"

log() {
	printf 'log:%s\n' "$*" >>"$event_log"
}

err() {
	printf 'err:%s\n' "$*" >>"$event_log"
}

require_command() {
	command -v "$1" >/dev/null 2>&1
}

service_running_state() {
	printf 'service_running_state\n' >>"$event_log"
	return "${TEST_SERVICE_RUNNING_RC:-0}"
}

read_config_json_for_path() {
	printf 'read_config_json_for_path:%s\n' "$1" >>"$event_log"
	printf '%s\n' "$old_json"
}

read_config_json() {
	printf 'read_config_json\n' >>"$event_log"
	printf '%s\n' "$new_json"
}

apply_config_file() {
	printf 'apply_config_file:%s\n' "$1" >>"$event_log"
	cp -f "$1" "$CLASH_CONFIG"
}

runtime_snapshot_valid() {
	return "${TEST_RUNTIME_SNAPSHOT_VALID_RC:-1}"
}

runtime_snapshot_policy_config_matches_current() {
	printf 'runtime_snapshot_policy_config_matches_current\n' >>"$event_log"
	return "${TEST_POLICY_CONFIG_MATCH_RC:-0}"
}

mihomo_hot_reload_config() {
	printf 'mihomo_hot_reload_config:%s\n' "$2" >>"$event_log"
	MIHOMO_API_REASON="${TEST_API_REASON:-api unavailable}"
	MIHOMO_API_HTTP_CODE="${TEST_API_HTTP_CODE:-}"
	return "${TEST_API_RC:-0}"
}

wait_for_current_mihomo_listeners() {
	printf 'wait_for_current_mihomo_listeners\n' >>"$event_log"
	return "${TEST_WAIT_LISTENERS_RC:-0}"
}

reload_runtime_state() {
	printf 'reload_runtime_state:allow=%s\n' "${MIHOWRT_ALLOW_MIHOMO_CONFIG_RELOAD:-0}" >>"$event_log"
	return "${TEST_RELOAD_RUNTIME_RC:-0}"
}

write_configs() {
	printf 'old\n' >"$CLASH_CONFIG"
	printf 'new\n' >"$tmpdir/candidate.yaml"
}

json_bool() {
	printf '%s\n' "$1" | jq -r "$2"
}

: >"$event_log"
write_configs
TEST_SERVICE_RUNNING_RC=1
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "saved" "$(json_bool "$result" '.action')" "stopped service should only save config"
assert_eq "false" "$(json_bool "$result" '.restart_required')" "stopped service should not request restart"
assert_file_not_contains "$event_log" "mihomo_hot_reload_config" "stopped service should not call Mihomo API"

: >"$event_log"
write_configs
TEST_SERVICE_RUNNING_RC=0
TEST_API_RC=0
new_json="$old_json"
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "hot_reloaded" "$(json_bool "$result" '.action')" "running service should hot reload non-policy config changes"
assert_eq "true" "$(json_bool "$result" '.hot_reloaded')" "hot reload result should flag hot_reloaded"
assert_eq "false" "$(json_bool "$result" '.policy_reloaded')" "non-policy config should skip policy reload"
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG" "hot reload should use active config path"
assert_file_not_contains "$event_log" "reload_runtime_state" "non-policy config should not reload policy"

: >"$event_log"
write_configs
TEST_API_RC=2
TEST_API_REASON="Mihomo API reload request failed"
TEST_API_HTTP_CODE="000"
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "restart_required" "$(json_bool "$result" '.action')" "API failure should request restart fallback"
assert_eq "true" "$(json_bool "$result" '.restart_required')" "API failure should set restart_required"
assert_eq "000" "$(json_bool "$result" '.http_code')" "API failure should expose HTTP code"

: >"$event_log"
write_configs
TEST_API_RC=0
new_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7875","mihomo_dns_listen":"127.0.0.1#7875","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "policy_reloaded" "$(json_bool "$result" '.action')" "runtime field change should hot reload then reload policy"
assert_eq "true" "$(json_bool "$result" '.policy_reloaded')" "runtime field change should flag policy reload"
assert_file_contains "$event_log" "wait_for_current_mihomo_listeners" "runtime field change should wait for reloaded listeners"
assert_file_contains "$event_log" "reload_runtime_state:allow=1" "runtime field change should allow Mihomo config drift after API reload"

: >"$event_log"
write_configs
new_json='{"external_controller":"127.0.0.1:9091","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "restart_required" "$(json_bool "$result" '.action')" "controller changes should require service restart"
assert_file_not_contains "$event_log" "mihomo_hot_reload_config" "controller changes should not call stale API reload"

pass "config hot reload apply"
