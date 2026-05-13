#!/bin/ash

append_source_interface() {
	local iface="$1"
	[ -n "$iface" ] || return 0

	if [ -n "$SOURCE_INTERFACES" ]; then
		SOURCE_INTERFACES="$SOURCE_INTERFACES $iface"
	else
		SOURCE_INTERFACES="$iface"
	fi
}

is_valid_iface_name() {
	case "$1" in
		''|*[!A-Za-z0-9_.:@-]*)
			return 1
			;;
	esac

	return 0
}

detect_lan_interface() {
	local iface=""

	iface="$(uci -q get network.lan.device 2>/dev/null)"
	iface="$(trim "$iface")"
	iface="${iface%%[[:space:]]*}"
	if is_valid_iface_name "$iface"; then
		printf '%s' "$iface"
		return 0
	fi

	iface="$(uci -q get network.lan.ifname 2>/dev/null)"
	iface="$(trim "$iface")"
	iface="${iface%%[[:space:]]*}"
	if is_valid_iface_name "$iface"; then
		printf '%s' "$iface"
		return 0
	fi

	return 1
}

default_source_interface() {
	detect_lan_interface || printf '%s' 'br-lan'
}

runtime_live_state_present() {
	local nft_state=1

	policy_route_state_read && return 0
	dns_backup_exists && return 0
	nft_table_exists
	nft_state=$?
	case "$nft_state" in
		0) return 0 ;;
		1) return 1 ;;
		*) return 0 ;;
	esac
}

load_runtime_config_from_yaml() {
	local config_json
	local config_errors

	config_json="$(read_config_json)" || return 1

	config_errors="$(printf '%s\n' "$config_json" | jq -r '.errors[]?')" || return 1
	if [ -n "$config_errors" ]; then
		printf '%s\n' "Policy config parse failed:" >&2
		printf '%s\n' "$config_errors" | while IFS= read -r message; do
			err "$message"
			printf '%s\n' "$message" >&2
		done
		return 1
	fi

	eval "$(
		printf '%s\n' "$config_json" | jq -r '
			@sh "MIHOMO_DNS_PORT=\(.dns_port) MIHOMO_DNS_LISTEN=\(.mihomo_dns_listen) MIHOMO_TPROXY_PORT=\(.tproxy_port) MIHOMO_ROUTING_MARK=\(.routing_mark) DNS_ENHANCED_MODE=\(.enhanced_mode) CATCH_FAKEIP=\(if .catch_fakeip then 1 else 0 end) FAKEIP_RANGE=\(.fake_ip_range)"
		'
	)" || return 1

	return 0
}

load_runtime_config() {
	local pkg_config="${PKG_CONFIG:-mihowrt}"

	SOURCE_INTERFACES=""

	config_load "$pkg_config" || return 1

	config_get POLICY_MODE "settings" "policy_mode" "direct-first"
	config_get_bool DNS_HIJACK "settings" "dns_hijack" 1
	config_get MIHOMO_ROUTE_TABLE_ID "settings" "route_table_id" ""
	config_get MIHOMO_ROUTE_RULE_PRIORITY "settings" "route_rule_priority" ""
	config_get_bool DISABLE_QUIC "settings" "disable_quic" 0
	config_list_foreach "settings" "source_network_interfaces" append_source_interface

	[ -n "$SOURCE_INTERFACES" ] || SOURCE_INTERFACES="$(default_source_interface)"
	load_runtime_config_from_yaml
}

validate_runtime_config() {
	local iface routing_mark="" intercept_mark=""
	local clash_bin="${CLASH_BIN:-/opt/clash/bin/clash}"
	local clash_config="${CLASH_CONFIG:-/opt/clash/config.yaml}"

	[ -x "$clash_bin" ] || {
		err "Mihomo binary missing at $clash_bin"
		return 1
	}

	[ -f "$clash_config" ] || {
		err "Mihomo config missing at $clash_config"
		return 1
	}

	is_dns_listen "$MIHOMO_DNS_LISTEN" || {
		err "Invalid Mihomo DNS listen value: $MIHOMO_DNS_LISTEN"
		return 1
	}

	is_valid_port "$MIHOMO_TPROXY_PORT" || {
		err "Invalid Mihomo TPROXY port: $MIHOMO_TPROXY_PORT"
		return 1
	}

	is_valid_uint32_mark "$MIHOMO_ROUTING_MARK" || {
		err "Invalid Mihomo routing mark: $MIHOMO_ROUTING_MARK"
		return 1
	}
	routing_mark="$(normalize_uint "$MIHOMO_ROUTING_MARK")"
	intercept_mark="$(normalize_uint "$(( ${NFT_INTERCEPT_MARK:-0x00001000} ))")"
	if [ "$routing_mark" = "$intercept_mark" ]; then
		err "Mihomo routing mark conflicts with MihoWRT intercept mark: $MIHOMO_ROUTING_MARK"
		return 1
	fi

	if [ -n "$MIHOMO_ROUTE_TABLE_ID" ]; then
		is_valid_route_table_id "$MIHOMO_ROUTE_TABLE_ID" || {
			err "Invalid route table id: $MIHOMO_ROUTE_TABLE_ID"
			return 1
		}
	fi

	if [ -n "$MIHOMO_ROUTE_RULE_PRIORITY" ]; then
		is_valid_route_rule_priority "$MIHOMO_ROUTE_RULE_PRIORITY" || {
			err "Invalid route rule priority: $MIHOMO_ROUTE_RULE_PRIORITY"
			return 1
		}
	fi

	case "${POLICY_MODE:-direct-first}" in
		direct-first|proxy-first)
			;;
		*)
			err "Invalid policy mode: ${POLICY_MODE:-}"
			return 1
			;;
	esac

	[ "$DNS_ENHANCED_MODE" = "fake-ip" ] || {
		err "Mihomo dns.enhanced-mode must be fake-ip"
		return 1
	}

	[ "$CATCH_FAKEIP" = "1" ] || {
		err "MihoWRT policy layer requires fake-ip interception"
		return 1
	}

	is_ipv4_cidr "$FAKEIP_RANGE" || {
		err "Invalid fake-ip range: $FAKEIP_RANGE"
		return 1
	}

	for iface in $SOURCE_INTERFACES; do
		is_valid_iface_name "$iface" || {
			err "Invalid source interface name: $iface"
			return 1
		}
	done

	ensure_policy_files
	return 0
}

prepare_runtime_state() {
	load_runtime_config || return 1
	validate_runtime_config || return 1
	apply_runtime_state
}

apply_runtime_state_internal() {
	ensure_dir "$PKG_TMP_DIR"

	policy_route_setup || return 1
	if ! nft_apply_policy; then
		policy_route_cleanup
		return 1
	fi

	if ! dns_setup; then
		dns_restore || true
		nft_remove_policy
		policy_route_cleanup
		return 1
	fi

	log "Prepared ${POLICY_MODE:-direct-first} policy state"
	return 0
}

apply_runtime_nft_policy_only() {
	ensure_dir "$PKG_TMP_DIR"
	nft_apply_policy || return 1
	log "Updated ${POLICY_MODE:-direct-first} nft policy"
	return 0
}

apply_runtime_state() {
	local lists_resolved=0

	if command -v policy_resolve_runtime_lists >/dev/null 2>&1; then
		policy_resolve_runtime_lists || return 2
		lists_resolved=1
	fi

	if ! apply_runtime_state_internal; then
		[ "$lists_resolved" -eq 0 ] || policy_clear_runtime_list_overrides
		return 1
	fi

	runtime_snapshot_save || {
		err "Failed to persist runtime snapshot"
		dns_restore || true
		nft_remove_policy || true
		policy_route_cleanup || true
		[ "$lists_resolved" -eq 0 ] || policy_clear_runtime_list_overrides
		return 1
	}

	[ "$lists_resolved" -eq 0 ] || policy_clear_runtime_list_overrides
	return 0
}

cleanup_runtime_state() {
	local rc=0
	local live_state_rc=1

	if runtime_live_state_present; then
		:
	else
		live_state_rc=$?
		case "$live_state_rc" in
			1)
				runtime_snapshot_clear
				log "Policy state already clean"
				return 0
				;;
			*)
				:
				;;
		esac
	fi

	dns_restore || {
		err "Failed to restore dnsmasq state during cleanup"
		rc=1
	}
	nft_remove_policy || {
		err "Failed to remove nft policy during cleanup"
		rc=1
	}
	policy_route_cleanup || {
		err "Failed to remove policy routing during cleanup"
		rc=1
	}

	if [ "$rc" -eq 0 ]; then
		runtime_snapshot_clear
		log "Cleaned up policy state"
		return 0
	fi

	err "Policy cleanup incomplete"
	return 1
}

recover_runtime_state() {
	runtime_live_state_present || return 0
	log "Recovering runtime state after unclean shutdown"
	cleanup_runtime_state
}

runtime_policy_ready_state() {
	runtime_snapshot_valid
}

reload_runtime_state() {
	local old_route_table_id="" old_route_rule_priority=""
	local new_route_table_id="" new_route_rule_priority=""
	local had_snapshot=0 snapshot_files_present=0 live_runtime_present=0
	local apply_rc=0

	if policy_route_state_read; then
		old_route_table_id="${ROUTE_TABLE_ID_EFFECTIVE:-}"
		old_route_rule_priority="${ROUTE_RULE_PRIORITY_EFFECTIVE:-}"
	fi
	runtime_snapshot_exists && snapshot_files_present=1 || snapshot_files_present=0
	runtime_snapshot_valid && had_snapshot=1 || had_snapshot=0
	runtime_live_state_present && live_runtime_present=1 || live_runtime_present=0

	load_runtime_config || return 1
	validate_runtime_config || return 1

	if [ "$had_snapshot" -eq 0 ] && [ "$snapshot_files_present" -eq 1 ]; then
		if [ "$live_runtime_present" -eq 1 ]; then
			err "Runtime snapshot invalid; refusing in-place reload while live policy state exists"
			return 1
		fi

		warn "Runtime snapshot invalid; applying policy from clean state"
		cleanup_runtime_state || return 1
		apply_runtime_state
		return $?
	fi

	if [ "$had_snapshot" -eq 0 ] && [ "$live_runtime_present" -eq 1 ]; then
		err "Runtime snapshot unavailable; refusing in-place reload while live policy state exists"
		return 1
	fi

	if [ "$had_snapshot" -eq 0 ]; then
		warn "Runtime snapshot unavailable; applying policy from clean state"
		cleanup_runtime_state || return 1
		apply_runtime_state
		return $?
	fi

	if ! runtime_snapshot_mihomo_config_matches_current; then
		err "Mihomo config changed since runtime snapshot; restart MihoWRT service to apply DNS/TPROXY/fake-ip settings"
		return 1
	fi

	apply_runtime_state
	apply_rc=$?
	if [ "$apply_rc" -ne 0 ]; then
		if [ "$apply_rc" -eq 2 ]; then
			err "Failed to prepare updated policy lists"
			return 1
		fi

		err "Failed to apply updated policy; restoring previous runtime state"
		runtime_snapshot_restore || {
			err "Failed to restore previous runtime state"
			return 1
		}
		return 1
	fi

	if policy_route_state_read; then
		new_route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
		new_route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	fi

	if [ -n "$old_route_table_id" ] && [ -n "$old_route_rule_priority" ] &&
		[ "$old_route_table_id:$old_route_rule_priority" != "$new_route_table_id:$new_route_rule_priority" ]; then
		policy_route_teardown_ids "$old_route_table_id" "$old_route_rule_priority" || {
			err "Failed to remove previous policy routing table $old_route_table_id priority $old_route_rule_priority"
			return 1
		}
	fi

	log "Reloaded ${POLICY_MODE:-direct-first} policy state"
	return 0
}

update_runtime_policy_lists() {
	local apply_rc=0 snapshot_rc=0 lists_changed=1

	runtime_snapshot_valid || {
		err "Runtime snapshot unavailable; cannot update remote policy lists safely"
		return 1
	}
	runtime_live_state_present || {
		err "Runtime policy state is not active; cannot update remote policy lists"
		return 1
	}

	policy_route_state_read || {
		err "Policy route state unavailable; cannot update remote policy lists safely"
		return 1
	}
	if ! runtime_snapshot_route_state_matches_live; then
		err "Policy route state changed since runtime snapshot; reload or restart MihoWRT before updating remote lists"
		return 1
	fi

	load_runtime_config || return 1
	validate_runtime_config || return 1

	if ! runtime_snapshot_mihomo_config_matches_current; then
		err "Mihomo config changed since runtime snapshot; restart MihoWRT service to apply DNS/TPROXY/fake-ip settings"
		return 1
	fi
	if ! runtime_snapshot_policy_config_matches_current; then
		err "Policy config changed since runtime snapshot; apply policy settings before updating remote lists"
		return 1
	fi

	policy_resolve_runtime_lists || {
		err "Failed to prepare updated policy lists"
		return 1
	}

	runtime_resolved_policy_lists_match_snapshot && lists_changed=0 || lists_changed=1
	if [ "$lists_changed" -eq 0 ]; then
		if ! runtime_snapshot_save; then
			policy_clear_runtime_list_overrides
			err "Failed to refresh runtime snapshot metadata"
			return 1
		fi

		policy_clear_runtime_list_overrides
		log "Remote policy lists unchanged; nft policy left untouched"
		printf '%s\n' 'updated=0'
		return 0
	fi

	apply_runtime_nft_policy_only
	apply_rc=$?
	if [ "$apply_rc" -ne 0 ]; then
		policy_clear_runtime_list_overrides
		err "Failed to apply updated policy lists; restoring previous runtime state"
		runtime_snapshot_restore || {
			err "Failed to restore previous runtime state"
			return 1
		}
		return 1
	fi

	runtime_snapshot_save
	snapshot_rc=$?
	if [ "$snapshot_rc" -ne 0 ]; then
		err "Failed to persist runtime snapshot"
		policy_clear_runtime_list_overrides
		runtime_snapshot_restore || {
			err "Failed to restore previous runtime state"
			return 1
		}
		return 1
	fi

	policy_clear_runtime_list_overrides

	log "Updated remote policy lists and refreshed ${POLICY_MODE:-direct-first} nft policy"
	printf '%s\n' 'updated=1'
	return 0
}

service_ready_runtime_state() {
	local dns_port="" active_json="" snapshot_dns_listen=""
	local tproxy_port=""
	local snapshot_vars=""

	service_running_state || return 1

	active_json="$(runtime_snapshot_readiness_json 2>/dev/null || true)"
	if [ -n "$active_json" ]; then
		snapshot_vars="$(printf '%s\n' "$active_json" | jq -r '
			@sh "dns_port=\(.mihomo_dns_port // "") tproxy_port=\(.mihomo_tproxy_port // "") snapshot_dns_listen=\(.mihomo_dns_listen // "")"
		' 2>/dev/null)" || return 1
		eval "$snapshot_vars" || return 1
		if [ -z "$dns_port" ]; then
			[ -n "$snapshot_dns_listen" ] && dns_port="$(dns_listen_port "$snapshot_dns_listen" 2>/dev/null || true)"
		fi
		mihomo_ready_state "$dns_port" "$tproxy_port" || return 1
		runtime_policy_ready_state
		return $?
	fi

	load_runtime_config || return 1
	dns_port="$(dns_listen_port "$MIHOMO_DNS_LISTEN" 2>/dev/null || true)"
	mihomo_ready_state "$dns_port" "$MIHOMO_TPROXY_PORT" || return 1
	runtime_policy_ready_state
}

service_enabled_state() {
	local pkg_name="${PKG_NAME:-mihowrt}"

	[ -x "/etc/init.d/$pkg_name" ] || return 1
	"/etc/init.d/$pkg_name" enabled >/dev/null 2>&1
}

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

load_status_config_json() {
	local config_json=""

	config_json="$(read_config_json 2>/dev/null || true)"
	[ -n "$config_json" ] || config_json="$(status_default_config_json)"
	printf '%s\n' "$config_json"
}

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
		route_table_id_effective="$ROUTE_TABLE_ID_EFFECTIVE"
		route_rule_priority_effective="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	fi

	if active_json="$(runtime_snapshot_status_json 2>&1)"; then
		runtime_snapshot_present=1
		runtime_snapshot_valid=1
	else
		runtime_snapshot_exists && runtime_snapshot_present=1 || runtime_snapshot_present=0
		if [ "$runtime_snapshot_present" -eq 1 ]; then
			runtime_errors_raw="$(trim "$active_json")"
			[ -n "$runtime_errors_raw" ] || runtime_errors_raw="Runtime snapshot is present but invalid"
		fi
		active_json="$(status_default_active_json)"
	fi

	status_vars="$(jq -nr \
		--argjson config "$config_json" \
		--argjson desired "$desired_json" \
		--argjson active "$active_json" \
		'@sh "dns_port=\($config.dns_port // "") tproxy_port=\($config.tproxy_port // "") desired_enabled=\($desired.enabled // false) desired_settings_loaded=\($desired.settings_loaded // false) active_enabled=\($active.enabled // false) readiness_dns_port=\($active.mihomo_dns_port // "") readiness_tproxy_port=\($active.mihomo_tproxy_port // "")"'
	)" || return 1
	eval "$status_vars" || return 1

	if [ "$service_running" = "1" ]; then
		[ -n "$readiness_dns_port" ] || readiness_dns_port="$dns_port"
		[ -n "$readiness_tproxy_port" ] || readiness_tproxy_port="$tproxy_port"

		if mihomo_ready_state "$readiness_dns_port" "$readiness_tproxy_port"; then
			if [ "$desired_settings_loaded" = "true" ] && [ "$desired_enabled" = "true" ]; then
				runtime_policy_ready_state && service_ready=1 || service_ready=0
			elif [ "$active_enabled" = "true" ]; then
				runtime_policy_ready_state && service_ready=1 || service_ready=0
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

status_json() {
	local config_json="" desired_json="" runtime_json="" comparison_json=""

	require_command jq || return 1
	config_json="$(load_status_config_json)" || return 1
	desired_json="$(load_status_desired_state_json)" || return 1
	runtime_json="$(load_status_runtime_state_json "$config_json" "$desired_json")" || return 1
	comparison_json="$(compare_status_runtime_state_json "$config_json" "$desired_json" "$runtime_json")" || return 1
	emit_status_json "$config_json" "$desired_json" "$runtime_json" "$comparison_json"
}

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
