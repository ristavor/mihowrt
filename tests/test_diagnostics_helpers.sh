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
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

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
		route_rule_priority) printf -v "$1" '%s' "10010" ;;
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

dns_backup_exists() {
	return 0
}

dns_backup_valid() {
	return 0
}

policy_route_state_read() {
	ROUTE_TABLE_ID_EFFECTIVE="201"
	ROUTE_RULE_PRIORITY_EFFECTIVE="10001"
	return 0
}

read_config_json() {
	cat <<'EOF'
{"config_path":"/opt/clash/config.yaml","dns_port":"7874","mihomo_dns_listen":"127.0.0.1#7874","tproxy_port":"7894","routing_mark":"2","enhanced_mode":"fake-ip","catch_fakeip":true,"fake_ip_range":"198.18.0.0/15","external_controller":"0.0.0.0:9090","external_controller_tls":"","secret":"","external_ui":"./ui","external_ui_name":"zashboard","errors":[]}
EOF
}

status_output="$(status_json)"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.service_running')" "status_json should expose running service state"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.service_enabled')" "status_json should expose boot-enabled state"
assert_eq "true" "$(printf '%s\n' "$status_output" | jq -r '.dns_backup_valid')" "status_json should expose dns backup validity"
assert_eq "auto" "$(printf '%s\n' "$status_output" | jq -r '.route_table_id')" "status_json should map empty route table to auto"
assert_eq "10010" "$(printf '%s\n' "$status_output" | jq -r '.route_rule_priority')" "status_json should expose configured route rule priority"
assert_eq "201" "$(printf '%s\n' "$status_output" | jq -r '.route_table_id_effective')" "status_json should expose effective route table id"
assert_eq "2" "$(printf '%s\n' "$status_output" | jq -r '.always_proxy_dst_count')" "status_json should expose destination list count"
assert_eq "wg0" "$(printf '%s\n' "$status_output" | jq -r '.source_network_interfaces[1]')" "status_json should expose source interfaces list"
assert_eq "127.0.0.1#7874" "$(printf '%s\n' "$status_output" | jq -r '.config.mihomo_dns_listen')" "status_json should embed parsed config summary"

logs_output="$(logs_json 2)"
assert_eq "true" "$(printf '%s\n' "$logs_output" | jq -r '.available')" "logs_json should report available logread command"
assert_eq "2" "$(printf '%s\n' "$logs_output" | jq -r '.limit')" "logs_json should preserve limit"
assert_eq "2" "$(printf '%s\n' "$logs_output" | jq -r '.lines | length')" "logs_json should keep only requested number of lines"
assert_eq "Mon Jan  1 00:00:02 2026 daemon.warn mihowrt[321]: warning line" "$(printf '%s\n' "$logs_output" | jq -r '.lines[0]')" "logs_json should keep earlier matching line within limit window"
assert_eq "Mon Jan  1 00:00:04 2026 daemon.info mihowrt: last line" "$(printf '%s\n' "$logs_output" | jq -r '.lines[1]')" "logs_json should keep latest matching line"

pass "diagnostics helpers"
