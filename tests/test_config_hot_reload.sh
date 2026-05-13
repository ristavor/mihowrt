#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

event_log="$tmpdir/events.log"
CLASH_CONFIG="$tmpdir/config.yaml"
SERVICE_PID_FILE="$tmpdir/mihomo.pid"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/config-io.sh"

old_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"0123456789abcdef0123456789abcdef0123456789abcdef","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
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
	if [ "$1" = "$CLASH_CONFIG" ]; then
		printf '%s\n' "$old_json"
	else
		printf '%s\n' "$new_json"
	fi
}

read_config_json() {
	printf 'read_config_json\n' >>"$event_log"
	printf '%s\n' "$new_json"
}

apply_config_file() {
	printf 'apply_config_file:%s\n' "$1" >>"$event_log"
	cp -f "$1" "$CLASH_CONFIG"
}

patch_config_api_defaults() {
	printf 'patch_config_api_defaults:%s\n' "$1" >>"$event_log"
	new_json="$(
		printf '%s\n' "$new_json" | jq -c '
			(if (.external_controller_unix // "") == "" then .external_controller_unix = "mihomo.sock" else . end) |
			(if (.external_controller // "") == "" then .external_controller = "192.168.7.1:9090" else . end) |
			(if (.secret // "") == "" then .secret = "0123456789abcdef0123456789abcdef0123456789abcdef" else . end)
		'
	)"
}

runtime_snapshot_valid() {
	return "${TEST_RUNTIME_SNAPSHOT_VALID_RC:-1}"
}

runtime_snapshot_policy_config_matches_current() {
	printf 'runtime_snapshot_policy_config_matches_current\n' >>"$event_log"
	return "${TEST_POLICY_CONFIG_MATCH_RC:-0}"
}

mihomo_hot_reload_config() {
	printf 'mihomo_hot_reload_config:%s:force=%s\n' "$2" "${3:-}" >>"$event_log"
	printf 'mihomo_hot_reload_config_api:%s:%s\n' "$(printf '%s\n' "$1" | jq -r '.external_controller // ""')" "$(printf '%s\n' "$1" | jq -r '.external_controller_unix // ""')" >>"$event_log"
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

validate_config_candidate() {
	printf 'validate_config_candidate:%s\n' "$1" >>"$event_log"
}

install_validated_config_candidate() {
	printf 'install_validated_config_candidate:%s\n' "$1" >>"$event_log"
	rm -f "$1"
}

mihomo_hot_reload_supported() {
	printf '%s\n' "$1" | jq -e '(.external_controller_unix // "") != "" or (.external_controller == "0.0.0.0:9090") or (.external_controller == "127.0.0.1:9090")' >/dev/null
}

TEST_LIVE_CONFIG_JSON=""
mihomo_api_live_or_config_json() {
	if [ -n "$TEST_LIVE_CONFIG_JSON" ]; then
		printf '%s\n' "$TEST_LIVE_CONFIG_JSON"
	else
		printf '%s\n' "$1"
	fi
}

subscription_store_auto_update_state() {
	printf 'subscription_store_auto_update_state:%s:%s:%s\n' "$1" "$2" "$3" >>"$event_log"
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
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=0" "non-port config change should hot reload without force"
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
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=1" "DNS port change should force Mihomo reload"
assert_file_contains "$event_log" "wait_for_current_mihomo_listeners" "runtime field change should wait for reloaded listeners"
assert_file_contains "$event_log" "reload_runtime_state:allow=1" "runtime field change should allow Mihomo config drift after API reload"

: >"$event_log"
write_configs
TEST_API_RC=0
new_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/16"}'
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "policy_reloaded" "$(json_bool "$result" '.action')" "non-port runtime field change should still reload policy"
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=0" "non-port runtime field change should hot reload without force"

: >"$event_log"
write_configs
new_json='{"external_controller":"127.0.0.1:9091","external_controller_tls":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "restart_required" "$(json_bool "$result" '.action')" "controller changes should require service restart"
assert_file_not_contains "$event_log" "mihomo_hot_reload_config" "controller changes should not call stale API reload"

: >"$event_log"
write_configs
new_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"custom.sock","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime "$tmpdir/candidate.yaml")"
assert_eq "restart_required" "$(json_bool "$result" '.action')" "Unix controller changes should require service restart"
assert_file_not_contains "$event_log" "mihomo_hot_reload_config" "Unix controller changes should not call stale API reload"

: >"$event_log"
write_configs
old_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"0123456789abcdef0123456789abcdef0123456789abcdef","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/16"}'
result="$(apply_config_runtime_auto_update "$tmpdir/candidate.yaml")"
assert_eq "policy_reloaded" "$(json_bool "$result" '.action')" "auto-update should hot reload safe config changes"
assert_file_contains "$event_log" "install_validated_config_candidate:$tmpdir/candidate.yaml" "auto-update should install safe hot-reloadable config"
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=0" "auto-update should hot reload without forced restart for non-port changes"
assert_file_not_contains "$event_log" "restart_required" "auto-update should not request restart for safe changes"

: >"$event_log"
write_configs
old_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"0123456789abcdef0123456789abcdef0123456789abcdef","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json='{"external_controller":"127.0.0.1:9091","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime_auto_update "$tmpdir/candidate.yaml")"
assert_eq "hot_reloaded" "$(json_bool "$result" '.action')" "auto-update should hot reload through live API when API fields drift"
assert_eq "true" "$(json_bool "$result" '.restart_required')" "auto-update should still flag manual restart after API field drift"
assert_file_contains "$event_log" "install_validated_config_candidate:$tmpdir/candidate.yaml" "auto-update should save config requiring manual restart"
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=0" "auto-update should call live API after API field drift"
assert_file_not_contains "$event_log" "subscription_store_auto_update_state:0::Mihomo API/UI settings changed; manual restart is required" "auto-update should not disable itself on API field drift"

: >"$event_log"
write_configs
old_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","external_controller_pipe":"","external_controller_cors":"external-controller-cors:\n  allow-private-network: false","external_doh_server":"/dns-query","api_tls":"tls:\n  certificate: ./old.crt","secret":"0123456789abcdef0123456789abcdef0123456789abcdef","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json='{"external_controller":"0.0.0.0:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","external_controller_pipe":"mihomo.pipe","external_controller_cors":"external-controller-cors:\n  allow-private-network: true","external_doh_server":"/dns-alt","api_tls":"tls:\n  certificate: ./new.crt","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime_auto_update "$tmpdir/candidate.yaml")"
assert_eq "hot_reloaded" "$(json_bool "$result" '.action')" "auto-update should hot reload API server-only field changes through live API"
assert_eq "true" "$(json_bool "$result" '.restart_required')" "auto-update should flag manual restart after API server-only field drift"
assert_file_contains "$event_log" "install_validated_config_candidate:$tmpdir/candidate.yaml" "auto-update should save config with API server drift"
assert_file_contains "$event_log" "mihomo_hot_reload_config:$CLASH_CONFIG:force=0" "auto-update should call live API after API server field drift"
assert_file_not_contains "$event_log" "subscription_store_auto_update_state:0::Mihomo API/UI settings changed; manual restart is required" "auto-update should not disable itself on API server drift"

: >"$event_log"
write_configs
TEST_LIVE_CONFIG_JSON='{"external_controller":"0.0.0.0:9090","external_controller_unix":"mihomo.sock","secret":"live-secret"}'
old_json='{"external_controller":"127.0.0.1:9091","external_controller_tls":"","external_controller_unix":"new.sock","secret":"new-secret","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json='{"external_controller":"127.0.0.1:9091","external_controller_tls":"","external_controller_unix":"new.sock","secret":"new-secret","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/16"}'
result="$(apply_config_runtime_auto_update "$tmpdir/candidate.yaml")"
assert_eq "policy_reloaded" "$(json_bool "$result" '.action')" "auto-update should keep using persisted live API across pending manual restart"
assert_eq "true" "$(json_bool "$result" '.restart_required')" "auto-update should keep manual restart flag while live API differs from saved config"
assert_file_contains "$event_log" "mihomo_hot_reload_config_api:0.0.0.0:9090:mihomo.sock" "auto-update should call old live API, not updated config API"
TEST_LIVE_CONFIG_JSON=""

: >"$event_log"
write_configs
old_json='{"external_controller":"192.168.7.1:9090","external_controller_tls":"","external_controller_unix":"mihomo.sock","secret":"0123456789abcdef0123456789abcdef0123456789abcdef","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
new_json='{"external_controller":"","external_controller_tls":"","external_controller_unix":"","secret":"","external_ui":"","external_ui_name":"","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15"}'
result="$(apply_config_runtime_auto_update "$tmpdir/candidate.yaml")"
assert_eq "hot_reloaded" "$(json_bool "$result" '.action')" "auto-update should patch missing API fields before hot reload checks"
assert_file_contains "$event_log" "patch_config_api_defaults:$tmpdir/candidate.yaml" "auto-update should patch downloaded config API defaults"
assert_file_contains "$event_log" "install_validated_config_candidate:$tmpdir/candidate.yaml" "auto-update should install config after API default patch"
assert_file_not_contains "$event_log" "subscription_store_auto_update_state:0:" "auto-update should not disable when missing API fields are patchable"

pass "config hot reload apply"
