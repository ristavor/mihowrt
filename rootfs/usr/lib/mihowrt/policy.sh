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

apply_runtime_state() {
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

cleanup_runtime_state() {
	dns_restore || true
	nft_remove_policy || true
	policy_route_cleanup || true
	log "Cleaned up direct-first policy state"
	return 0
}

recover_runtime_state() {
	dns_recovery_needed || return 0
	log "Recovering runtime state after unclean shutdown"
	cleanup_runtime_state
}

reload_runtime_state() {
	load_runtime_config || return 1
	validate_runtime_config || return 1
	cleanup_runtime_state

	if [ "$ENABLED" != "1" ]; then
		log "Policy layer disabled; runtime state left clean"
		return 0
	fi

	apply_runtime_state
}

status_runtime_state() {
	load_runtime_config || return 1
	PROXY_DST_COUNT="$(count_valid_list_entries "$DST_LIST_FILE")"
	PROXY_SRC_COUNT="$(count_valid_list_entries "$SRC_LIST_FILE")"

	echo "enabled=$ENABLED"
	echo "mihomo_dns_port=$MIHOMO_DNS_PORT"
	echo "mihomo_dns_listen=$MIHOMO_DNS_LISTEN"
	echo "dns_hijack=$DNS_HIJACK"
	echo "mihomo_tproxy_port=$MIHOMO_TPROXY_PORT"
	echo "mihomo_routing_mark=$MIHOMO_ROUTING_MARK"
	echo "route_table_id=${MIHOMO_ROUTE_TABLE_ID:-auto}"
	echo "route_rule_priority=${MIHOMO_ROUTE_RULE_PRIORITY:-auto}"
	echo "disable_quic=$DISABLE_QUIC"
	echo "dns_enhanced_mode=${DNS_ENHANCED_MODE:-}"
	echo "catch_fakeip=$CATCH_FAKEIP"
	echo "fakeip_range=$FAKEIP_RANGE"
	echo "source_network_interfaces=$SOURCE_INTERFACES"
	echo "always_proxy_dst_count=$PROXY_DST_COUNT"
	echo "always_proxy_src_count=$PROXY_SRC_COUNT"
}
