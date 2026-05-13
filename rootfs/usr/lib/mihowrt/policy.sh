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
