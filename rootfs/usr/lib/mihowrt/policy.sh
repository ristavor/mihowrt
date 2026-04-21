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
	printf '%s' "$1" | grep -qE '^[A-Za-z0-9_.:@-]+$'
}

detect_lan_interface() {
	local iface=""

	iface="$(uci -q get network.lan.device 2>/dev/null)"
	iface="$(printf '%s\n' "$iface" | awk 'NR == 1 { print $1 }')"
	if is_valid_iface_name "$iface"; then
		printf '%s' "$iface"
		return 0
	fi

	iface="$(uci -q get network.lan.ifname 2>/dev/null)"
	iface="$(printf '%s\n' "$iface" | awk 'NR == 1 { print $1 }')"
	if is_valid_iface_name "$iface"; then
		printf '%s' "$iface"
		return 0
	fi

	return 1
}

default_source_interface() {
	detect_lan_interface || printf '%s' 'br-lan'
}

runtime_snapshot_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/runtime.snapshot.json}"
}

runtime_snapshot_dst_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_DST_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/always_proxy_dst.snapshot}"
}

runtime_snapshot_src_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_SRC_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/always_proxy_src.snapshot}"
}

runtime_snapshot_exists() {
	[ -f "$(runtime_snapshot_file)" ] || return 1
	[ -f "$(runtime_snapshot_dst_file)" ] || return 1
	[ -f "$(runtime_snapshot_src_file)" ] || return 1
}

runtime_snapshot_clear() {
	rm -f "$(runtime_snapshot_file)" "$(runtime_snapshot_dst_file)" "$(runtime_snapshot_src_file)"
}

runtime_snapshot_cleanup_files() {
	rm -f "$@"
}

runtime_snapshot_copy_file() {
	local src="$1"
	local dst="$2"

	if [ -f "$src" ]; then
		cp -f "$src" "$dst" || return 1
	else
		: > "$dst" || return 1
	fi

	return 0
}

runtime_snapshot_backup_file() {
	local src="$1"
	local backup="$2"

	[ -f "$src" ] || return 0
	cp -f "$src" "$backup" || return 1
	return 0
}

runtime_snapshot_restore_file() {
	local dst="$1"
	local backup="$2"

	if [ -f "$backup" ]; then
		mv -f "$backup" "$dst" 2>/dev/null || cp -f "$backup" "$dst" || return 1
	else
		rm -f "$dst"
	fi

	return 0
}

runtime_snapshot_restore_backups() {
	local snapshot_file="$1"
	local dst_snapshot="$2"
	local src_snapshot="$3"
	local snapshot_backup="$4"
	local dst_backup="$5"
	local src_backup="$6"

	runtime_snapshot_restore_file "$snapshot_file" "$snapshot_backup" || true
	runtime_snapshot_restore_file "$dst_snapshot" "$dst_backup" || true
	runtime_snapshot_restore_file "$src_snapshot" "$src_backup" || true
	runtime_snapshot_cleanup_files "$snapshot_backup" "$dst_backup" "$src_backup"
}

runtime_snapshot_save() {
	local snapshot_file dst_snapshot src_snapshot
	local snapshot_tmp dst_tmp src_tmp
	local snapshot_backup dst_backup src_backup
	local route_table_id="" route_rule_priority=""
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"

	require_command jq || return 1
	policy_route_state_read || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"
	route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
	route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"

	ensure_dir "$(dirname "$snapshot_file")" || return 1
	snapshot_tmp="${snapshot_file}.tmp.$$"
	dst_tmp="${dst_snapshot}.tmp.$$"
	src_tmp="${src_snapshot}.tmp.$$"
	snapshot_backup="${snapshot_file}.bak.$$"
	dst_backup="${dst_snapshot}.bak.$$"
	src_backup="${src_snapshot}.bak.$$"

	runtime_snapshot_copy_file "$dst_list_file" "$dst_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}
	runtime_snapshot_copy_file "$src_list_file" "$src_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}

	jq -nc \
		--arg enabled "$ENABLED" \
		--arg dns_hijack "$DNS_HIJACK" \
		--arg mihomo_dns_port "$MIHOMO_DNS_PORT" \
		--arg mihomo_dns_listen "$MIHOMO_DNS_LISTEN" \
		--arg mihomo_tproxy_port "$MIHOMO_TPROXY_PORT" \
		--arg mihomo_routing_mark "$MIHOMO_ROUTING_MARK" \
		--arg route_table_id_effective "$route_table_id" \
		--arg route_rule_priority_effective "$route_rule_priority" \
		--arg disable_quic "$DISABLE_QUIC" \
		--arg dns_enhanced_mode "$DNS_ENHANCED_MODE" \
		--arg catch_fakeip "$CATCH_FAKEIP" \
		--arg fakeip_range "$FAKEIP_RANGE" \
		--arg source_interfaces "$SOURCE_INTERFACES" \
		'{
			enabled: ($enabled == "1"),
			dns_hijack: ($dns_hijack == "1"),
			mihomo_dns_port: $mihomo_dns_port,
			mihomo_dns_listen: $mihomo_dns_listen,
			mihomo_tproxy_port: $mihomo_tproxy_port,
			mihomo_routing_mark: $mihomo_routing_mark,
			route_table_id_effective: $route_table_id_effective,
			route_rule_priority_effective: $route_rule_priority_effective,
			disable_quic: ($disable_quic == "1"),
			dns_enhanced_mode: $dns_enhanced_mode,
			catch_fakeip: ($catch_fakeip == "1"),
			fakeip_range: $fakeip_range,
			source_network_interfaces: ($source_interfaces | split(" ") | map(select(length > 0)))
		}' > "$snapshot_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}

	runtime_snapshot_backup_file "$snapshot_file" "$snapshot_backup" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$snapshot_backup" "$dst_backup" "$src_backup"
		return 1
	}
	runtime_snapshot_backup_file "$dst_snapshot" "$dst_backup" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$snapshot_backup" "$dst_backup" "$src_backup"
		return 1
	}
	runtime_snapshot_backup_file "$src_snapshot" "$src_backup" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$snapshot_backup" "$dst_backup" "$src_backup"
		return 1
	}

	mv -f "$dst_tmp" "$dst_snapshot" || {
		runtime_snapshot_restore_backups "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup"
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}
	mv -f "$src_tmp" "$src_snapshot" || {
		runtime_snapshot_restore_backups "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup"
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}
	mv -f "$snapshot_tmp" "$snapshot_file" || {
		runtime_snapshot_restore_backups "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup"
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp"
		return 1
	}

	runtime_snapshot_cleanup_files "$snapshot_backup" "$dst_backup" "$src_backup"
	log "Saved runtime snapshot"
	return 0
}

runtime_snapshot_load() {
	local snapshot_file snapshot_json=""
	local dst_snapshot src_snapshot

	require_command jq || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"

	[ -f "$snapshot_file" ] || return 1
	[ -f "$dst_snapshot" ] || return 1
	[ -f "$src_snapshot" ] || return 1

	snapshot_json="$(cat "$snapshot_file")" || return 1

	eval "$(
		printf '%s\n' "$snapshot_json" | jq -r '
			@sh "ENABLED=\(if .enabled then 1 else 0 end) DNS_HIJACK=\(if .dns_hijack then 1 else 0 end) MIHOMO_DNS_PORT=\(.mihomo_dns_port // "") MIHOMO_DNS_LISTEN=\(.mihomo_dns_listen // "") MIHOMO_TPROXY_PORT=\(.mihomo_tproxy_port // "") MIHOMO_ROUTING_MARK=\(.mihomo_routing_mark // "") MIHOMO_ROUTE_TABLE_ID=\(.route_table_id_effective // "") MIHOMO_ROUTE_RULE_PRIORITY=\(.route_rule_priority_effective // "") DISABLE_QUIC=\(if .disable_quic then 1 else 0 end) DNS_ENHANCED_MODE=\(.dns_enhanced_mode // "") CATCH_FAKEIP=\(if .catch_fakeip then 1 else 0 end) FAKEIP_RANGE=\(.fakeip_range // "") SOURCE_INTERFACES=\((.source_network_interfaces // []) | join(" "))"
		'
	)" || return 1

	POLICY_DST_LIST_FILE="$dst_snapshot"
	POLICY_SRC_LIST_FILE="$src_snapshot"
	return 0
}

runtime_snapshot_restore() {
	local prev_dst_list_file="" prev_src_list_file=""
	local prev_dst_list_set=0 prev_src_list_set=0
	local rc=0

	[ "${POLICY_DST_LIST_FILE+x}" = x ] && {
		prev_dst_list_set=1
		prev_dst_list_file="$POLICY_DST_LIST_FILE"
	}
	[ "${POLICY_SRC_LIST_FILE+x}" = x ] && {
		prev_src_list_set=1
		prev_src_list_file="$POLICY_SRC_LIST_FILE"
	}

	runtime_snapshot_load || return 1
	apply_runtime_state_internal || rc=$?

	if [ "$prev_dst_list_set" -eq 1 ]; then
		POLICY_DST_LIST_FILE="$prev_dst_list_file"
	else
		unset POLICY_DST_LIST_FILE
	fi

	if [ "$prev_src_list_set" -eq 1 ]; then
		POLICY_SRC_LIST_FILE="$prev_src_list_file"
	else
		unset POLICY_SRC_LIST_FILE
	fi

	[ "$rc" -eq 0 ] || return "$rc"

	log "Restored previous runtime snapshot"
	return 0
}

runtime_live_state_present() {
	policy_route_state_read && return 0
	dns_backup_exists && return 0
	nft_table_exists && return 0
	return 1
}

runtime_snapshot_status_json() {
	local snapshot_file dst_snapshot src_snapshot
	local dst_count=0 src_count=0

	require_command jq || return 1
	runtime_snapshot_exists || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"
	dst_count="$(count_valid_list_entries "$dst_snapshot")"
	src_count="$(count_valid_list_entries "$src_snapshot")"

	jq -c \
		--arg dst_count "$dst_count" \
		--arg src_count "$src_count" \
		'{
			present: true,
			enabled: (.enabled // false),
			dns_hijack: (.dns_hijack // false),
			mihomo_dns_port: (.mihomo_dns_port // ""),
			mihomo_dns_listen: (.mihomo_dns_listen // ""),
			mihomo_tproxy_port: (.mihomo_tproxy_port // ""),
			mihomo_routing_mark: (.mihomo_routing_mark // ""),
			route_table_id: (.route_table_id_effective // ""),
			route_rule_priority: (.route_rule_priority_effective // ""),
			disable_quic: (.disable_quic // false),
			dns_enhanced_mode: (.dns_enhanced_mode // ""),
			catch_fakeip: (.catch_fakeip // false),
			fakeip_range: (.fakeip_range // ""),
			source_network_interfaces: (.source_network_interfaces // []),
			always_proxy_dst_count: ($dst_count | tonumber? // 0),
			always_proxy_src_count: ($src_count | tonumber? // 0)
		}' "$snapshot_file"
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
	SOURCE_INTERFACES=""

	config_load "$PKG_CONFIG" || return 1

	config_get_bool ENABLED "settings" "enabled" 1
	config_get_bool DNS_HIJACK "settings" "dns_hijack" 1
	config_get MIHOMO_ROUTE_TABLE_ID "settings" "route_table_id" ""
	config_get MIHOMO_ROUTE_RULE_PRIORITY "settings" "route_rule_priority" ""
	config_get_bool DISABLE_QUIC "settings" "disable_quic" 0
	config_list_foreach "settings" "source_network_interfaces" append_source_interface

	[ -n "$SOURCE_INTERFACES" ] || SOURCE_INTERFACES="$(default_source_interface)"
	load_runtime_config_from_yaml
}

validate_runtime_config() {
	local iface

	[ -x "$CLASH_BIN" ] || {
		err "Mihomo binary missing at $CLASH_BIN"
		return 1
	}

	[ -f "$CLASH_CONFIG" ] || {
		err "Mihomo config missing at $CLASH_CONFIG"
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

	is_uint "$MIHOMO_ROUTING_MARK" || {
		err "Invalid Mihomo routing mark: $MIHOMO_ROUTING_MARK"
		return 1
	}

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

	if [ "$CATCH_FAKEIP" = "1" ]; then
		is_ipv4_cidr "$FAKEIP_RANGE" || {
			err "Invalid fake-ip range: $FAKEIP_RANGE"
			return 1
		}
	fi

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

	log "Prepared direct-first policy state"
	return 0
}

apply_runtime_state() {
	apply_runtime_state_internal || return 1

	runtime_snapshot_save || {
		err "Failed to persist runtime snapshot"
		dns_restore || true
		nft_remove_policy || true
		policy_route_cleanup || true
		return 1
	}

	return 0
}

cleanup_runtime_state() {
	local rc=0

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
	runtime_snapshot_clear

	if [ "$rc" -eq 0 ]; then
		log "Cleaned up direct-first policy state"
		return 0
	fi

	err "Direct-first policy cleanup incomplete"
	return 1
}

recover_runtime_state() {
	dns_recovery_needed || return 0
	log "Recovering runtime state after unclean shutdown"
	cleanup_runtime_state
}

reload_runtime_state() {
	local old_route_table_id="" old_route_rule_priority=""
	local new_route_table_id="" new_route_rule_priority=""
	local had_snapshot=0 live_runtime_present=0

	if policy_route_state_read; then
		old_route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
		old_route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	fi
	runtime_snapshot_exists && had_snapshot=1 || had_snapshot=0
	runtime_live_state_present && live_runtime_present=1 || live_runtime_present=0

	load_runtime_config || return 1
	validate_runtime_config || return 1

	if [ "$ENABLED" != "1" ]; then
		cleanup_runtime_state || return 1
		log "Policy layer disabled; runtime state left clean"
		return 0
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

	if ! apply_runtime_state; then
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
		policy_route_teardown_ids "$old_route_table_id" "$old_route_rule_priority"
	fi

	log "Reloaded direct-first policy state"
	return 0
}

service_enabled_state() {
	local pkg_name="${PKG_NAME:-mihowrt}"

	[ -x "/etc/init.d/$pkg_name" ] || return 1
	"/etc/init.d/$pkg_name" enabled >/dev/null 2>&1
}

service_running_state() {
	local pid="" pid_file="${SERVICE_PID_FILE:-/var/run/mihowrt/mihomo.pid}"

	[ -f "$pid_file" ] || return 1
	IFS= read -r pid < "$pid_file" 2>/dev/null || pid=""
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

status_json() {
	local enabled=0 dns_hijack=0 route_table_id="" route_rule_priority="" disable_quic=0
	local source_interfaces="" proxy_dst_count=0 proxy_src_count=0
	local service_enabled=0 service_running=0 dns_backup_exists_flag=0 dns_backup_valid_flag=0
	local route_state_present=0 route_table_id_effective="" route_rule_priority_effective=""
	local config_json="" fallback_config_json="" active_json="" runtime_matches_desired="true"
	local pkg_config="${PKG_CONFIG:-mihowrt}" clash_config="${CLASH_CONFIG:-/opt/clash/config.yaml}"
	local dst_list_file="${DST_LIST_FILE:-/opt/clash/lst/always_proxy_dst.txt}"
	local src_list_file="${SRC_LIST_FILE:-/opt/clash/lst/always_proxy_src.txt}"
	local runtime_snapshot_present=0 runtime_live_present=0 runtime_safe_reload_ready=1
	local settings_loaded=0 status_errors_raw=""

	require_command jq || return 1
	SOURCE_INTERFACES=""

	config_json="$(read_config_json 2>/dev/null || true)"
	if [ -z "$config_json" ]; then
		fallback_config_json="$(jq -nc \
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
			}')"
		config_json="$fallback_config_json"
	fi

	if config_load "$pkg_config" 2>/dev/null; then
		settings_loaded=1
		config_get_bool enabled "settings" "enabled" 1
		config_get_bool dns_hijack "settings" "dns_hijack" 1
		config_get route_table_id "settings" "route_table_id" ""
		config_get route_rule_priority "settings" "route_rule_priority" ""
		config_get_bool disable_quic "settings" "disable_quic" 0
		config_list_foreach "settings" "source_network_interfaces" append_source_interface
		source_interfaces="$SOURCE_INTERFACES"
	else
		status_errors_raw="Failed to read /etc/config/$pkg_config"
	fi

	if [ "$settings_loaded" -eq 1 ] && [ -z "$source_interfaces" ]; then
		source_interfaces="$(default_source_interface)"
	fi
	proxy_dst_count="$(count_valid_list_entries "$dst_list_file")"
	proxy_src_count="$(count_valid_list_entries "$src_list_file")"

	service_enabled_state && service_enabled=1 || service_enabled=0
	service_running_state && service_running=1 || service_running=0
	dns_backup_exists && dns_backup_exists_flag=1 || dns_backup_exists_flag=0
	dns_backup_valid && dns_backup_valid_flag=1 || dns_backup_valid_flag=0
	runtime_live_state_present && runtime_live_present=1 || runtime_live_present=0

	if policy_route_state_read; then
		route_state_present=1
		route_table_id_effective="$ROUTE_TABLE_ID_EFFECTIVE"
		route_rule_priority_effective="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	fi

	active_json="$(runtime_snapshot_status_json 2>/dev/null || true)"
	if [ -n "$active_json" ]; then
		runtime_snapshot_present=1
	else
		active_json="$(jq -nc '{
			present: false,
			enabled: false,
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
			always_proxy_dst_count: 0,
			always_proxy_src_count: 0
		}')"
	fi

	if [ "$settings_loaded" -eq 0 ]; then
		runtime_matches_desired="false"
	elif [ "$runtime_snapshot_present" -eq 0 ] && [ "$runtime_live_present" -eq 1 ]; then
		runtime_safe_reload_ready=0
		runtime_matches_desired="false"
	elif [ "$runtime_snapshot_present" -eq 1 ]; then
		runtime_matches_desired="$(
			jq -nr \
				--argjson config "$config_json" \
				--argjson active "$active_json" \
				--arg dns_hijack "$dns_hijack" \
				--arg route_table_id "$route_table_id" \
				--arg route_rule_priority "$route_rule_priority" \
				--arg disable_quic "$disable_quic" \
				--arg source_interfaces "$source_interfaces" \
				--arg proxy_dst_count "$proxy_dst_count" \
				--arg proxy_src_count "$proxy_src_count" \
				'(
					($active.dns_hijack == ($dns_hijack == "1")) and
					($active.disable_quic == ($disable_quic == "1")) and
					($active.source_network_interfaces == ($source_interfaces | split(" ") | map(select(length > 0)))) and
					($active.always_proxy_dst_count == ($proxy_dst_count | tonumber? // 0)) and
					($active.always_proxy_src_count == ($proxy_src_count | tonumber? // 0)) and
					(($route_table_id == "") or ($active.route_table_id == $route_table_id)) and
					(($route_rule_priority == "") or ($active.route_rule_priority == $route_rule_priority)) and
					(($active.mihomo_dns_listen // "") == ($config.mihomo_dns_listen // "")) and
					(($active.mihomo_tproxy_port // "") == ($config.tproxy_port // "")) and
					(($active.mihomo_routing_mark // "") == ($config.routing_mark // "")) and
					(($active.dns_enhanced_mode // "") == ($config.enhanced_mode // "")) and
					(($active.catch_fakeip // false) == ($config.catch_fakeip // false)) and
					(($active.fakeip_range // "") == ($config.fake_ip_range // ""))
				)'
		)"
	fi

	jq -nc \
		--argjson config "$config_json" \
		--argjson active "$active_json" \
		--arg enabled "$enabled" \
		--arg dns_hijack "$dns_hijack" \
		--arg route_table_id "$route_table_id" \
		--arg route_rule_priority "$route_rule_priority" \
		--arg disable_quic "$disable_quic" \
		--arg source_interfaces "$source_interfaces" \
		--arg proxy_dst_count "$proxy_dst_count" \
		--arg proxy_src_count "$proxy_src_count" \
		--arg service_enabled "$service_enabled" \
		--arg service_running "$service_running" \
		--arg dns_backup_exists "$dns_backup_exists_flag" \
		--arg dns_backup_valid "$dns_backup_valid_flag" \
		--arg route_state_present "$route_state_present" \
		--arg route_table_id_effective "$route_table_id_effective" \
		--arg route_rule_priority_effective "$route_rule_priority_effective" \
		--arg runtime_snapshot_present "$runtime_snapshot_present" \
		--arg runtime_live_present "$runtime_live_present" \
		--arg runtime_safe_reload_ready "$runtime_safe_reload_ready" \
		--arg runtime_matches_desired "$runtime_matches_desired" \
		--arg settings_loaded "$settings_loaded" \
		--arg status_errors_raw "$status_errors_raw" \
		'{
			service_enabled: ($service_enabled == "1"),
			service_running: ($service_running == "1"),
			dns_backup_exists: ($dns_backup_exists == "1"),
			dns_backup_valid: ($dns_backup_valid == "1"),
			route_state_present: ($route_state_present == "1"),
			route_table_id_effective: $route_table_id_effective,
			route_rule_priority_effective: $route_rule_priority_effective,
			enabled: ($enabled == "1"),
			dns_hijack: ($dns_hijack == "1"),
			route_table_id: (if $settings_loaded != "1" then "unavailable" elif $route_table_id == "" then "auto" else $route_table_id end),
			route_rule_priority: (if $settings_loaded != "1" then "unavailable" elif $route_rule_priority == "" then "auto" else $route_rule_priority end),
			disable_quic: ($disable_quic == "1"),
			source_network_interfaces: ($source_interfaces | split(" ") | map(select(length > 0))),
			always_proxy_dst_count: ($proxy_dst_count | tonumber? // 0),
			always_proxy_src_count: ($proxy_src_count | tonumber? // 0),
			runtime_snapshot_present: ($runtime_snapshot_present == "1"),
			runtime_live_state_present: ($runtime_live_present == "1"),
			runtime_safe_reload_ready: ($runtime_safe_reload_ready == "1"),
			runtime_matches_desired: ($runtime_matches_desired == "true"),
			active: $active,
			config: $config,
			errors: (($config.errors // []) + ($status_errors_raw | split("\n") | map(select(length > 0))))
		}'
}

status_runtime_state() {
	local status_json_output=""

	require_command jq || return 1
	status_json_output="$(status_json)" || return 1

	printf '%s\n' "$status_json_output" | jq -r '
		"enabled=\(if .enabled then 1 else 0 end)",
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
		"runtime_snapshot_present=\(if .runtime_snapshot_present then 1 else 0 end)",
		"runtime_live_state_present=\(if .runtime_live_state_present then 1 else 0 end)",
		"runtime_safe_reload_ready=\(if .runtime_safe_reload_ready then 1 else 0 end)",
		"runtime_matches_desired=\(if .runtime_matches_desired then 1 else 0 end)",
		(if .runtime_snapshot_present then
			"active_enabled=\(if .active.enabled then 1 else 0 end)",
			"active_dns_hijack=\(if .active.dns_hijack then 1 else 0 end)",
			"active_route_table_id=\(.active.route_table_id // "")",
			"active_route_rule_priority=\(.active.route_rule_priority // "")",
			"active_disable_quic=\(if .active.disable_quic then 1 else 0 end)",
			"active_source_network_interfaces=\((.active.source_network_interfaces // []) | join(" "))",
			"active_always_proxy_dst_count=\(.active.always_proxy_dst_count // 0)",
			"active_always_proxy_src_count=\(.active.always_proxy_src_count // 0)"
		else empty end)
	'
}
