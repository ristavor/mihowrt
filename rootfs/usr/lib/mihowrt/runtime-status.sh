#!/bin/ash

# Historical readiness helper: snapshot validity means router policy was applied.
runtime_policy_ready_state() {
	runtime_snapshot_valid
}

# Read DNS/TPROXY readiness ports from active snapshot.
load_snapshot_readiness_ports() {
	local active_json="" snapshot_dns_listen=""
	local snapshot_vars=""

	STATUS_READY_DNS_PORT=""
	STATUS_READY_TPROXY_PORT=""

	active_json="$(runtime_snapshot_readiness_json 2>/dev/null || true)"
	[ -n "$active_json" ] || return 1

	snapshot_vars="$(printf '%s\n' "$active_json" | jq -r '
		@sh "STATUS_READY_DNS_PORT=\(.mihomo_dns_port // "") STATUS_READY_TPROXY_PORT=\(.mihomo_tproxy_port // "") snapshot_dns_listen=\(.mihomo_dns_listen // "")"
	' 2>/dev/null)" || return 1
	eval "$snapshot_vars" || return 1
	if [ -z "$STATUS_READY_DNS_PORT" ]; then
		[ -n "$snapshot_dns_listen" ] && STATUS_READY_DNS_PORT="$(dns_listen_port "$snapshot_dns_listen" 2>/dev/null || true)"
	fi
}

# Read DNS/TPROXY readiness ports from current config as fallback.
load_config_readiness_ports() {
	STATUS_READY_DNS_PORT=""
	STATUS_READY_TPROXY_PORT=""

	load_runtime_config || return 1
	STATUS_READY_DNS_PORT="$(dns_listen_port "$MIHOMO_DNS_LISTEN" 2>/dev/null || true)"
	STATUS_READY_TPROXY_PORT="$MIHOMO_TPROXY_PORT"
}

# CLI readiness probe that includes service-running check.
service_ready_runtime_state() {
	service_running_state || return 1
	service_ready_runtime_state_for_running_service
}

# Fast readiness probe after caller already checked service is running.
service_ready_runtime_state_for_running_service() {
	if load_snapshot_readiness_ports; then
		mihomo_ports_ready_state "$STATUS_READY_DNS_PORT" "$STATUS_READY_TPROXY_PORT"
		return $?
	fi

	load_config_readiness_ports || return 1
	mihomo_ports_ready_state "$STATUS_READY_DNS_PORT" "$STATUS_READY_TPROXY_PORT" || return 1
	runtime_policy_ready_state
}

# Query init autostart state.
service_enabled_state() {
	local pkg_name="${PKG_NAME:-mihowrt}"

	[ -x "/etc/init.d/$pkg_name" ] || return 1
	"/etc/init.d/$pkg_name" enabled >/dev/null 2>&1
}

# Small JSON used by LuCI config page polling.
service_state_json() {
	local service_enabled=0 service_running=0 service_ready=0

	require_command jq || return 1

	service_enabled_state && service_enabled=1 || service_enabled=0
	service_running_state && service_running=1 || service_running=0
	if [ "$service_running" -eq 1 ]; then
		service_ready_runtime_state_for_running_service && service_ready=1 || service_ready=0
	fi

	jq -nc \
		--arg service_enabled "$service_enabled" \
		--arg service_running "$service_running" \
		--arg service_ready "$service_ready" \
		'{
			service_enabled: ($service_enabled == "1"),
			service_running: ($service_running == "1"),
			service_ready: ($service_ready == "1"),
			errors: []
		}'
}

# Fallback config object when config parsing cannot run.
status_default_config_json() {
	local clash_config="${CLASH_CONFIG:-/opt/clash/config.yaml}"

	jq -nc \
		--arg config_path "$clash_config" \
		'{
			config_path: $config_path,
			dns_listen_raw: "",
			dns_port: "",
			mihomo_dns_listen: "",
			tproxy_port: "",
			routing_mark: "",
			enhanced_mode: "",
			catch_fakeip: false,
			fake_ip_range: "",
			external_controller: "",
			external_controller_tls: "",
			secret: "",
			external_ui: "",
			external_ui_name: "",
			errors: ["Failed to read config"]
		}'
}

# Fallback active object when no valid snapshot exists.
status_default_active_json() {
	jq -nc '{
		present: false,
		enabled: false,
		policy_mode: "direct-first",
		dns_hijack: false,
		mihomo_dns_port: "",
		mihomo_dns_listen: "",
		mihomo_tproxy_port: "",
		mihomo_routing_mark: "",
		route_table_id: "",
		route_rule_priority: "",
		disable_quic: false,
		dns_enhanced_mode: "",
		catch_fakeip: false,
		fakeip_range: "",
		source_network_interfaces: [],
		always_proxy_dst_source_hash: "",
		always_proxy_src_source_hash: "",
		direct_dst_source_hash: "",
		always_proxy_dst_count: 0,
		always_proxy_src_count: 0,
		direct_dst_count: 0
	}'
}

# Load active snapshot for diagnostics, preserving invalid-snapshot errors in
# status output instead of failing the whole response.
load_status_active_snapshot_json() {
	STATUS_ACTIVE_JSON=""
	STATUS_RUNTIME_SNAPSHOT_PRESENT=0
	STATUS_RUNTIME_SNAPSHOT_VALID=0
	STATUS_RUNTIME_ERRORS_RAW=""

	if STATUS_ACTIVE_JSON="$(runtime_snapshot_status_json 2>&1)"; then
		STATUS_RUNTIME_SNAPSHOT_PRESENT=1
		STATUS_RUNTIME_SNAPSHOT_VALID=1
		return 0
	fi

	runtime_snapshot_exists && STATUS_RUNTIME_SNAPSHOT_PRESENT=1 || STATUS_RUNTIME_SNAPSHOT_PRESENT=0
	if [ "$STATUS_RUNTIME_SNAPSHOT_PRESENT" -eq 1 ]; then
		STATUS_RUNTIME_ERRORS_RAW="$(trim "$STATUS_ACTIVE_JSON")"
		[ -n "$STATUS_RUNTIME_ERRORS_RAW" ] || STATUS_RUNTIME_ERRORS_RAW="Runtime snapshot is present but invalid"
	fi
	STATUS_ACTIVE_JSON="$(status_default_active_json)"
}

# Load current config parse result for diagnostics.
load_status_config_json() {
	local config_json=""

	config_json="$(read_config_json 2>/dev/null || true)"
	[ -n "$config_json" ] || config_json="$(status_default_config_json)"
	printf '%s\n' "$config_json"
}

# Load desired UCI/list state from disk.
load_status_desired_state_json() {
	local dns_hijack=0 route_table_id="" route_rule_priority="" disable_quic=0
	local source_interfaces="" proxy_dst_count=0 proxy_src_count=0 direct_dst_count=0 settings_loaded=0
	local proxy_dst_url_count=0 proxy_src_url_count=0 direct_dst_url_count=0
	local proxy_dst_source_hash="" proxy_src_source_hash="" direct_dst_source_hash=""
	local policy_mode="direct-first"
	local status_errors_raw=""
	local pkg_config="${PKG_CONFIG:-mihowrt}"
	local dst_list_file="${DST_LIST_FILE:-/opt/clash/lst/always_proxy_dst.txt}"
	local src_list_file="${SRC_LIST_FILE:-/opt/clash/lst/always_proxy_src.txt}"
	local direct_list_file="${DIRECT_DST_LIST_FILE:-/opt/clash/lst/direct_dst.txt}"

	SOURCE_INTERFACES=""

	if config_load "$pkg_config" 2>/dev/null; then
		settings_loaded=1
		config_get_bool dns_hijack "settings" "dns_hijack" 1
		config_get route_table_id "settings" "route_table_id" ""
		config_get route_rule_priority "settings" "route_rule_priority" ""
		config_get policy_mode "settings" "policy_mode" "direct-first"
		config_get_bool disable_quic "settings" "disable_quic" 0
		config_list_foreach "settings" "source_network_interfaces" append_source_interface
		source_interfaces="$SOURCE_INTERFACES"
	else
		status_errors_raw="Failed to read /etc/config/$pkg_config"
	fi

	if [ "$settings_loaded" -eq 1 ] && [ -z "$source_interfaces" ]; then
		source_interfaces="$(default_source_interface)"
	fi
	proxy_dst_source_hash="$(policy_list_fingerprint "$dst_list_file")"
	proxy_src_source_hash="$(policy_list_fingerprint "$src_list_file")"
	direct_dst_source_hash="$(policy_list_fingerprint "$direct_list_file")"

	case "$policy_mode" in
	direct-first)
		proxy_dst_count="$(count_valid_list_entries "$dst_list_file")"
		proxy_src_count="$(count_valid_list_entries "$src_list_file")"
		proxy_dst_url_count="$(count_remote_list_urls "$dst_list_file")"
		proxy_src_url_count="$(count_remote_list_urls "$src_list_file")"
		;;
	proxy-first)
		direct_dst_count="$(count_valid_list_entries "$direct_list_file")"
		direct_dst_url_count="$(count_remote_list_urls "$direct_list_file")"
		;;
	*)
		status_errors_raw="${status_errors_raw}${status_errors_raw:+
}Invalid policy mode: $policy_mode"
		;;
	esac

	jq -nc \
		--arg policy_mode "$policy_mode" \
		--arg dns_hijack "$dns_hijack" \
		--arg route_table_id "$route_table_id" \
		--arg route_rule_priority "$route_rule_priority" \
		--arg disable_quic "$disable_quic" \
		--arg source_interfaces "$source_interfaces" \
		--arg proxy_dst_count "$proxy_dst_count" \
		--arg proxy_src_count "$proxy_src_count" \
		--arg direct_dst_count "$direct_dst_count" \
		--arg proxy_dst_url_count "$proxy_dst_url_count" \
		--arg proxy_src_url_count "$proxy_src_url_count" \
		--arg direct_dst_url_count "$direct_dst_url_count" \
		--arg proxy_dst_source_hash "$proxy_dst_source_hash" \
		--arg proxy_src_source_hash "$proxy_src_source_hash" \
		--arg direct_dst_source_hash "$direct_dst_source_hash" \
		--arg settings_loaded "$settings_loaded" \
		--arg status_errors_raw "$status_errors_raw" \
		'{
			enabled: true,
			policy_mode: $policy_mode,
			dns_hijack: ($dns_hijack == "1"),
			route_table_id_raw: $route_table_id,
			route_rule_priority_raw: $route_rule_priority,
			route_table_id: (if $settings_loaded != "1" then "unavailable" elif $route_table_id == "" then "auto" else $route_table_id end),
			route_rule_priority: (if $settings_loaded != "1" then "unavailable" elif $route_rule_priority == "" then "auto" else $route_rule_priority end),
			disable_quic: ($disable_quic == "1"),
			source_network_interfaces: ($source_interfaces | split(" ") | map(select(length > 0))),
			always_proxy_dst_count: ($proxy_dst_count | tonumber? // 0),
			always_proxy_src_count: ($proxy_src_count | tonumber? // 0),
			direct_dst_count: ($direct_dst_count | tonumber? // 0),
			always_proxy_dst_remote_url_count: ($proxy_dst_url_count | tonumber? // 0),
			always_proxy_src_remote_url_count: ($proxy_src_url_count | tonumber? // 0),
			direct_dst_remote_url_count: ($direct_dst_url_count | tonumber? // 0),
			always_proxy_dst_source_hash: $proxy_dst_source_hash,
			always_proxy_src_source_hash: $proxy_src_source_hash,
			direct_dst_source_hash: $direct_dst_source_hash,
			settings_loaded: ($settings_loaded == "1"),
			errors: ($status_errors_raw | split("\n") | map(select(length > 0)))
	}'
}

# Summarize live runtime artifacts: service, DNS backup, route state, snapshot,
# and listener readiness.
load_status_runtime_state_json() {
	local config_json="${1:-}" desired_json="${2:-}"
	local service_enabled=0 service_running=0 service_ready=0 dns_backup_exists_flag=0 dns_backup_valid_flag=0
	local dns_recovery_backup_active_flag=0 dns_recovery_backup_valid_flag=0
	local route_state_present=0 route_table_id_effective="" route_rule_priority_effective=""
	local runtime_snapshot_present=0 runtime_snapshot_valid=0 runtime_live_present=0 active_json="" runtime_errors_raw=""
	local dns_port="" tproxy_port="" readiness_dns_port="" readiness_tproxy_port=""
	local desired_enabled="false" desired_settings_loaded="false" active_enabled="false"
	local status_vars=""

	service_enabled_state && service_enabled=1 || service_enabled=0
	service_running_state && service_running=1 || service_running=0
	dns_persist_backup_exists && dns_backup_exists_flag=1 || dns_backup_exists_flag=0
	dns_persist_backup_valid && dns_backup_valid_flag=1 || dns_backup_valid_flag=0
	dns_backup_exists && dns_recovery_backup_active_flag=1 || dns_recovery_backup_active_flag=0
	dns_backup_valid && dns_recovery_backup_valid_flag=1 || dns_recovery_backup_valid_flag=0
	runtime_live_state_present && runtime_live_present=1 || runtime_live_present=0

	if policy_route_state_read; then
		route_state_present=1
		route_table_id_effective="${ROUTE_TABLE_ID_EFFECTIVE:-}"
		route_rule_priority_effective="${ROUTE_RULE_PRIORITY_EFFECTIVE:-}"
	fi

	load_status_active_snapshot_json || return 1
	active_json="$STATUS_ACTIVE_JSON"
	runtime_snapshot_present="$STATUS_RUNTIME_SNAPSHOT_PRESENT"
	runtime_snapshot_valid="$STATUS_RUNTIME_SNAPSHOT_VALID"
	runtime_errors_raw="$STATUS_RUNTIME_ERRORS_RAW"

	status_vars="$(
		jq -nr \
			--argjson config "$config_json" \
			--argjson desired "$desired_json" \
			--argjson active "$active_json" \
			'@sh "dns_port=\($config.dns_port // "") tproxy_port=\($config.tproxy_port // "") desired_enabled=\($desired.enabled // false) desired_settings_loaded=\($desired.settings_loaded // false) active_enabled=\($active.enabled // false) readiness_dns_port=\($active.mihomo_dns_port // "") readiness_tproxy_port=\($active.mihomo_tproxy_port // "")"'
	)" || return 1
	eval "$status_vars" || return 1

	if [ "$service_running" = "1" ]; then
		[ -n "$readiness_dns_port" ] || readiness_dns_port="$dns_port"
		[ -n "$readiness_tproxy_port" ] || readiness_tproxy_port="$tproxy_port"

		if mihomo_ports_ready_state "$readiness_dns_port" "$readiness_tproxy_port"; then
			if [ "$desired_settings_loaded" = "true" ] && [ "$desired_enabled" = "true" ]; then
				[ "$runtime_snapshot_valid" = "1" ] && service_ready=1 || service_ready=0
			elif [ "$active_enabled" = "true" ]; then
				[ "$runtime_snapshot_valid" = "1" ] && service_ready=1 || service_ready=0
			else
				service_ready=1
			fi
		fi
	fi

	jq -nc \
		--argjson active "$active_json" \
		--arg service_enabled "$service_enabled" \
		--arg service_running "$service_running" \
		--arg service_ready "$service_ready" \
		--arg dns_backup_exists "$dns_backup_exists_flag" \
		--arg dns_backup_valid "$dns_backup_valid_flag" \
		--arg dns_recovery_backup_active "$dns_recovery_backup_active_flag" \
		--arg dns_recovery_backup_valid "$dns_recovery_backup_valid_flag" \
		--arg route_state_present "$route_state_present" \
		--arg route_table_id_effective "$route_table_id_effective" \
		--arg route_rule_priority_effective "$route_rule_priority_effective" \
		--arg runtime_snapshot_present "$runtime_snapshot_present" \
		--arg runtime_snapshot_valid "$runtime_snapshot_valid" \
		--arg runtime_live_present "$runtime_live_present" \
		--arg runtime_errors_raw "$runtime_errors_raw" \
		'{
			service_enabled: ($service_enabled == "1"),
			service_running: ($service_running == "1"),
			service_ready: ($service_ready == "1"),
			dns_backup_exists: ($dns_backup_exists == "1"),
			dns_backup_valid: ($dns_backup_valid == "1"),
			dns_recovery_backup_active: ($dns_recovery_backup_active == "1"),
			dns_recovery_backup_valid: ($dns_recovery_backup_valid == "1"),
			route_state_present: ($route_state_present == "1"),
			route_table_id_effective: $route_table_id_effective,
			route_rule_priority_effective: $route_rule_priority_effective,
			runtime_snapshot_present: ($runtime_snapshot_present == "1"),
			runtime_snapshot_valid: ($runtime_snapshot_valid == "1"),
			runtime_live_state_present: ($runtime_live_present == "1"),
			active: $active,
			errors: ($runtime_errors_raw | split("\n") | map(select(length > 0)))
		}'
}

# Compare active snapshot with desired disk state. Remote URLs are compared by
# source fingerprint because effective remote content changes only after fetch.
compare_status_runtime_state_json() {
	local config_json="$1"
	local desired_json="$2"
	local runtime_json="$3"

	jq -nc \
		--argjson config "$config_json" \
		--argjson desired "$desired_json" \
		--argjson runtime "$runtime_json" \
		'def list_matches($active_count; $desired_count; $active_hash; $desired_hash; $remote_urls):
			if (($remote_urls // 0) > 0) then
				(($active_hash // "") != "" and ($desired_hash // "") != "" and ($active_hash == $desired_hash))
			else
				($active_count == $desired_count)
			end;
		{
			runtime_safe_reload_ready: (
				if ($desired.settings_loaded | not) then true
				elif ($runtime.runtime_snapshot_present and ($runtime.runtime_snapshot_valid | not) and $runtime.runtime_live_state_present) then false
				elif (($runtime.runtime_snapshot_present | not) and $runtime.runtime_live_state_present) then false
				else true
				end
			),
			runtime_matches_desired: (
				if ($desired.settings_loaded | not) then false
				elif ($runtime.runtime_snapshot_present and ($runtime.runtime_snapshot_valid | not)) then false
				elif ($desired.enabled | not) then
					(($runtime.runtime_snapshot_present | not) and ($runtime.runtime_live_state_present | not))
				elif (($runtime.runtime_snapshot_present | not) and $runtime.runtime_live_state_present) then false
				elif $runtime.runtime_snapshot_present then
					(
						($runtime.active.enabled == $desired.enabled) and
						(($runtime.active.policy_mode // "direct-first") == ($desired.policy_mode // "direct-first")) and
						($runtime.active.dns_hijack == $desired.dns_hijack) and
						($runtime.active.disable_quic == $desired.disable_quic) and
						($runtime.active.source_network_interfaces == $desired.source_network_interfaces) and
						list_matches($runtime.active.always_proxy_dst_count; $desired.always_proxy_dst_count; $runtime.active.always_proxy_dst_source_hash; $desired.always_proxy_dst_source_hash; $desired.always_proxy_dst_remote_url_count) and
						list_matches($runtime.active.always_proxy_src_count; $desired.always_proxy_src_count; $runtime.active.always_proxy_src_source_hash; $desired.always_proxy_src_source_hash; $desired.always_proxy_src_remote_url_count) and
						list_matches(($runtime.active.direct_dst_count // 0); ($desired.direct_dst_count // 0); $runtime.active.direct_dst_source_hash; $desired.direct_dst_source_hash; $desired.direct_dst_remote_url_count) and
						(($desired.route_table_id_raw == "") or ($runtime.active.route_table_id == $desired.route_table_id_raw)) and
						(($desired.route_rule_priority_raw == "") or ($runtime.active.route_rule_priority == $desired.route_rule_priority_raw)) and
						(($runtime.active.mihomo_dns_listen // "") == ($config.mihomo_dns_listen // "")) and
						(($runtime.active.mihomo_tproxy_port // "") == ($config.tproxy_port // "")) and
						(($runtime.active.mihomo_routing_mark // "") == ($config.routing_mark // "")) and
						(($runtime.active.dns_enhanced_mode // "") == ($config.enhanced_mode // "")) and
						(($runtime.active.catch_fakeip // false) == ($config.catch_fakeip // false)) and
						(($runtime.active.fakeip_range // "") == ($config.fake_ip_range // ""))
						)
					else false
					end
				)
			}'
}

# Compose final status JSON from independent config/desired/runtime pieces.
emit_status_json() {
	local config_json="$1"
	local desired_json="$2"
	local runtime_json="$3"
	local comparison_json="$4"

	jq -nc \
		--argjson config "$config_json" \
		--argjson desired "$desired_json" \
		--argjson runtime "$runtime_json" \
		--argjson comparison "$comparison_json" \
		'{
			service_enabled: $runtime.service_enabled,
			service_running: $runtime.service_running,
			service_ready: $runtime.service_ready,
			dns_backup_exists: $runtime.dns_backup_exists,
			dns_backup_valid: $runtime.dns_backup_valid,
			dns_recovery_backup_active: $runtime.dns_recovery_backup_active,
			dns_recovery_backup_valid: $runtime.dns_recovery_backup_valid,
			route_state_present: $runtime.route_state_present,
			route_table_id_effective: $runtime.route_table_id_effective,
			route_rule_priority_effective: $runtime.route_rule_priority_effective,
			enabled: $desired.enabled,
			policy_mode: $desired.policy_mode,
			dns_hijack: $desired.dns_hijack,
			route_table_id: $desired.route_table_id,
			route_rule_priority: $desired.route_rule_priority,
			disable_quic: $desired.disable_quic,
			source_network_interfaces: $desired.source_network_interfaces,
			always_proxy_dst_count: $desired.always_proxy_dst_count,
			always_proxy_src_count: $desired.always_proxy_src_count,
			direct_dst_count: $desired.direct_dst_count,
			always_proxy_dst_remote_url_count: $desired.always_proxy_dst_remote_url_count,
			always_proxy_src_remote_url_count: $desired.always_proxy_src_remote_url_count,
			direct_dst_remote_url_count: $desired.direct_dst_remote_url_count,
			runtime_snapshot_present: $runtime.runtime_snapshot_present,
			runtime_snapshot_valid: $runtime.runtime_snapshot_valid,
			runtime_live_state_present: $runtime.runtime_live_state_present,
			runtime_safe_reload_ready: $comparison.runtime_safe_reload_ready,
			runtime_matches_desired: $comparison.runtime_matches_desired,
			active: $runtime.active,
			config: $config,
			errors: (($config.errors // []) + ($desired.errors // []) + ($runtime.errors // []))
		}'
}

# Public machine-readable diagnostics entrypoint.
status_json() {
	local config_json="" desired_json="" runtime_json="" comparison_json=""

	require_command jq || return 1
	config_json="$(load_status_config_json)" || return 1
	desired_json="$(load_status_desired_state_json)" || return 1
	runtime_json="$(load_status_runtime_state_json "$config_json" "$desired_json")" || return 1
	comparison_json="$(compare_status_runtime_state_json "$config_json" "$desired_json" "$runtime_json")" || return 1
	emit_status_json "$config_json" "$desired_json" "$runtime_json" "$comparison_json"
}

# Human-readable diagnostics entrypoint for CLI use.
status_runtime_state() {
	local status_json_output=""

	require_command jq || return 1
	status_json_output="$(status_json)" || return 1

	printf '%s\n' "$status_json_output" | jq -r '
			"enabled=\(if .enabled then 1 else 0 end)",
			"policy_mode=\(.policy_mode // "direct-first")",
			"service_ready=\(if .service_ready then 1 else 0 end)",
			"mihomo_dns_port=\(.config.dns_port // "")",
		"mihomo_dns_listen=\(.config.mihomo_dns_listen // "")",
		"dns_hijack=\(if .dns_hijack then 1 else 0 end)",
		"mihomo_tproxy_port=\(.config.tproxy_port // "")",
		"mihomo_routing_mark=\(.config.routing_mark // "")",
		"route_table_id=\(.route_table_id // "auto")",
		"route_rule_priority=\(.route_rule_priority // "auto")",
		"disable_quic=\(if .disable_quic then 1 else 0 end)",
		"dns_enhanced_mode=\(.config.enhanced_mode // "")",
		"catch_fakeip=\(if .config.catch_fakeip then 1 else 0 end)",
		"fakeip_range=\(.config.fake_ip_range // "")",
		"source_network_interfaces=\((.source_network_interfaces // []) | join(" "))",
		"always_proxy_dst_count=\(.always_proxy_dst_count // 0)",
		"always_proxy_src_count=\(.always_proxy_src_count // 0)",
		"direct_dst_count=\(.direct_dst_count // 0)",
		"always_proxy_dst_remote_url_count=\(.always_proxy_dst_remote_url_count // 0)",
		"always_proxy_src_remote_url_count=\(.always_proxy_src_remote_url_count // 0)",
		"direct_dst_remote_url_count=\(.direct_dst_remote_url_count // 0)",
		"runtime_snapshot_present=\(if .runtime_snapshot_present then 1 else 0 end)",
		"runtime_snapshot_valid=\(if .runtime_snapshot_valid then 1 else 0 end)",
		"runtime_live_state_present=\(if .runtime_live_state_present then 1 else 0 end)",
		"runtime_safe_reload_ready=\(if .runtime_safe_reload_ready then 1 else 0 end)",
		"runtime_matches_desired=\(if .runtime_matches_desired then 1 else 0 end)",
		(if .runtime_snapshot_present then
			"active_enabled=\(if .active.enabled then 1 else 0 end)",
			"active_policy_mode=\(.active.policy_mode // "direct-first")",
			"active_dns_hijack=\(if .active.dns_hijack then 1 else 0 end)",
			"active_route_table_id=\(.active.route_table_id // "")",
			"active_route_rule_priority=\(.active.route_rule_priority // "")",
			"active_disable_quic=\(if .active.disable_quic then 1 else 0 end)",
			"active_source_network_interfaces=\((.active.source_network_interfaces // []) | join(" "))",
			"active_always_proxy_dst_count=\(.active.always_proxy_dst_count // 0)",
			"active_always_proxy_src_count=\(.active.always_proxy_src_count // 0)",
			"active_direct_dst_count=\(.active.direct_dst_count // 0)"
		else empty end)
	'
}
