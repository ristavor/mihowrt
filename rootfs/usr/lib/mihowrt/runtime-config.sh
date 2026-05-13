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
