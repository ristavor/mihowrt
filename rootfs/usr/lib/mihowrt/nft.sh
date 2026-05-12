#!/bin/ash

nft_delete_table_named_if_exists() {
	local table="$1"
	local table_state=1

	nft_table_exists_named "$table"
	table_state=$?
	case "$table_state" in
		0)
			:
			;;
		1)
			return 0
			;;
		*)
			return 1
			;;
	esac

	nft delete table inet "$table" >/dev/null 2>&1 || return 1
	nft_table_exists_named "$table"
	table_state=$?
	[ "$table_state" -eq 1 ]
}

nft_delete_table_if_exists() {
	nft_delete_table_named_if_exists "$NFT_TABLE_NAME"
}

nft_table_exists_named() {
	local table="$1"
	local tables_output=""

	have_command nft || return 2
	tables_output="$(nft list tables inet 2>/dev/null)" || return 2
	printf '%s\n' "$tables_output" | awk -v table="$table" '
		$1 == "table" && $2 == "inet" && $3 == table { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

nft_table_exists() {
	nft_table_exists_named "$NFT_TABLE_NAME"
}

nft_emit_delete_existing_tables() {
	local table table_state

	for table in "$NFT_TABLE_NAME" ${NFT_LEGACY_TABLE_NAMES:-}; do
		nft_table_exists_named "$table"
		table_state=$?
		case "$table_state" in
			0)
				nft_emit_line "delete table inet $table"
				;;
			1)
				:
				;;
			*)
				return 1
				;;
		esac
	done
}

nft_emit_line() {
	printf '%s\n' "$1" >> "$NFT_BATCH_FILE"
}

nft_cleanup_batch_file() {
	[ -n "${NFT_BATCH_FILE:-}" ] && rm -f "$NFT_BATCH_FILE"
}

nft_emit_elements_chunk() {
	local set_name="$1"
	local chunk="$2"

	[ -n "$chunk" ] || return 0
	nft_emit_line "add element inet $NFT_TABLE_NAME $set_name { $chunk }"
}

nft_emit_policy_file_to_set() {
	local file="$1"
	local set_name="$2"
	local total_count_var="$3"
	local set_count_var="$4"
	local chunk=""
	local chunk_count=0
	local total_count=0
	local set_count=0
	local scoped_count=0
	local invalid_count=0
	local line addr

	[ -f "$file" ] || {
		eval "$total_count_var=0"
		eval "$set_count_var=0"
		return 0
	}

	while IFS= read -r line; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac

		if ! is_policy_entry "$line"; then
			invalid_count=$((invalid_count + 1))
			warn "Skipping invalid policy entry '$line' in $file"
			continue
		fi

		total_count=$((total_count + 1))

		if policy_entry_has_ports "$line"; then
			scoped_count=$((scoped_count + 1))
			continue
		fi

		addr="$(policy_entry_ip "$line")"
		if [ -n "$chunk" ]; then
			chunk="$chunk,$addr"
		else
			chunk="$addr"
		fi

		chunk_count=$((chunk_count + 1))
		set_count=$((set_count + 1))

		if [ "$chunk_count" -ge 512 ]; then
			nft_emit_elements_chunk "$set_name" "$chunk" || return 1
			chunk=""
			chunk_count=0
		fi
	done < "$file"

	nft_emit_elements_chunk "$set_name" "$chunk" || return 1
	eval "$total_count_var=$total_count"
	eval "$set_count_var=$set_count"
	log "Loaded $set_count unscoped and $scoped_count port-scoped entries, skipped $invalid_count invalid entries for set $set_name"
	return 0
}

nft_emit_ipv4_file_to_set() {
	local file="$1"
	local set_name="$2"
	local count_var="$3"
	local total_count=0

	nft_emit_policy_file_to_set "$file" "$set_name" total_count "$count_var"
}

nft_emit_base_table() {
	nft_emit_line "add table inet $NFT_TABLE_NAME"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET { type ipv4_addr; flags interval; auto-merge; }"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET { type ipv4_addr; flags interval; auto-merge; }"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_DIRECT_DST_SET { type ipv4_addr; flags interval; auto-merge; }"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_LOCALV4_SET { type ipv4_addr; flags interval; auto-merge; }"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_IFACE_SET { type ifname; flags interval; }"
	nft_emit_line "add element inet $NFT_TABLE_NAME $NFT_LOCALV4_SET {
		0.0.0.0/8,
		10.0.0.0/8,
		100.64.0.0/10,
		127.0.0.0/8,
		169.254.0.0/16,
		172.16.0.0/12,
		192.0.0.0/24,
		192.0.2.0/24,
		192.88.99.0/24,
		192.168.0.0/16,
		198.51.100.0/24,
		203.0.113.0/24,
		224.0.0.0/4,
		240.0.0.0-255.255.255.255
	}"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_DNS_HIJACK { type nat hook prerouting priority dstnat; policy accept; }"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING { type filter hook prerouting priority -150; policy accept; }"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PREROUTING_POLICY"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_OUTPUT { type route hook output priority -150; policy accept; }"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY { type filter hook prerouting priority -100; policy accept; }"
}

nft_emit_interface_set() {
	local iface

	for iface in $SOURCE_INTERFACES; do
		nft_emit_line "add element inet $NFT_TABLE_NAME $NFT_IFACE_SET { $iface }"
	done
}

nft_emit_rule() {
	local chain="$1"
	local expr="$2"

	nft_emit_line "add rule inet $NFT_TABLE_NAME $chain $expr"
}

nft_emit_policy_port_rules() {
	local file="$1"
	local field="$2"
	local chain="$3"
	local action="$4"
	local line addr ports ports_expr addr_expr

	[ -f "$file" ] || return 0

	while IFS= read -r line; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac
		is_policy_entry "$line" || continue
		policy_entry_has_ports "$line" || continue

		addr="$(policy_entry_ip "$line")"
		ports="$(policy_entry_ports "$line")"
		ports_expr="$(policy_ports_nft_expr "$ports")" || return 1
		if [ -n "$addr" ]; then
			addr_expr="ip $field $addr"
		else
			addr_expr="meta nfproto ipv4"
		fi
		nft_emit_rule "$chain" "$addr_expr tcp dport $ports_expr $action"
		nft_emit_rule "$chain" "$addr_expr udp dport $ports_expr $action"
	done < "$file"
}

nft_emit_policy_quic_port_rejects() {
	local file="$1"
	local field="$2"
	local chain="$3"
	local line addr ports addr_expr

	[ -f "$file" ] || return 0

	while IFS= read -r line; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac
		is_policy_entry "$line" || continue
		policy_entry_has_ports "$line" || continue

		addr="$(policy_entry_ip "$line")"
		ports="$(policy_entry_ports "$line")"
		policy_ports_include_port "$ports" 443 || continue
		if [ -n "$addr" ]; then
			addr_expr="ip $field $addr"
		else
			addr_expr="meta nfproto ipv4"
		fi
		nft_emit_rule "$chain" "$addr_expr udp dport 443 reject"
	done < "$file"
}

nft_emit_common_policy_start() {
	local dns_port

	if [ "$DNS_HIJACK" = "1" ]; then
		dns_port="$(dns_listen_port "$MIHOMO_DNS_LISTEN")"
		nft_emit_rule "$NFT_CHAIN_DNS_HIJACK" "iifname @$NFT_IFACE_SET ip daddr != @$NFT_LOCALV4_SET udp dport 53 redirect to :$dns_port"
		nft_emit_rule "$NFT_CHAIN_DNS_HIJACK" "iifname @$NFT_IFACE_SET ip daddr != @$NFT_LOCALV4_SET tcp dport 53 redirect to :$dns_port"
	fi

	nft_emit_rule "$NFT_CHAIN_PREROUTING" "iifname @$NFT_IFACE_SET jump $NFT_CHAIN_PREROUTING_POLICY"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_LOCALV4_SET return"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta mark $NFT_INTERCEPT_MARK return"
	if [ "$DNS_HIJACK" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "udp dport 53 return"
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "tcp dport 53 return"
	fi
}

nft_emit_common_proxy_rules() {
	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto tcp tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"
	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto udp tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"

	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $MIHOMO_ROUTING_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $NFT_INTERCEPT_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "tcp dport $MIHOMO_TPROXY_PORT return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "udp dport $MIHOMO_TPROXY_PORT return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_LOCALV4_SET return"
}

nft_emit_direct_first_policy_rules() {
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"

	nft_emit_common_policy_start

	if [ "$DISABLE_QUIC" = "1" ]; then
		if [ "$CATCH_FAKEIP" = "1" ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject"
		fi
		nft_emit_policy_quic_port_rejects "$dst_list_file" "daddr" "$NFT_CHAIN_PREROUTING_POLICY" || return 1
		if [ "${NFT_PROXY_SRC_SET_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET udp dport 443 reject"
		fi
		nft_emit_policy_quic_port_rejects "$src_list_file" "saddr" "$NFT_CHAIN_PREROUTING_POLICY" || return 1
	fi

	if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	nft_emit_policy_port_rules "$dst_list_file" "daddr" "$NFT_CHAIN_PREROUTING_POLICY" "meta mark set $NFT_INTERCEPT_MARK" || return 1
	if [ "${NFT_PROXY_SRC_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	nft_emit_policy_port_rules "$src_list_file" "saddr" "$NFT_CHAIN_PREROUTING_POLICY" "meta mark set $NFT_INTERCEPT_MARK" || return 1
	if [ "$CATCH_FAKEIP" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi

	nft_emit_common_proxy_rules

	if [ "$DISABLE_QUIC" = "1" ]; then
		if [ "$CATCH_FAKEIP" = "1" ]; then
			nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject"
		fi
		nft_emit_policy_quic_port_rejects "$dst_list_file" "daddr" "$NFT_CHAIN_OUTPUT" || return 1
	fi

	if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	nft_emit_policy_port_rules "$dst_list_file" "daddr" "$NFT_CHAIN_OUTPUT" "meta mark set $NFT_INTERCEPT_MARK" || return 1
	if [ "$CATCH_FAKEIP" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
}

nft_emit_proxy_first_policy_rules() {
	local direct_list_file="${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}"

	nft_emit_common_policy_start
	if [ "${NFT_DIRECT_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_DIRECT_DST_SET return"
	fi
	nft_emit_policy_port_rules "$direct_list_file" "daddr" "$NFT_CHAIN_PREROUTING_POLICY" "return" || return 1
	if [ "$DISABLE_QUIC" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "udp dport 443 reject"
	fi
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"

	nft_emit_common_proxy_rules
	if [ "${NFT_DIRECT_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_DIRECT_DST_SET return"
	fi
	nft_emit_policy_port_rules "$direct_list_file" "daddr" "$NFT_CHAIN_OUTPUT" "return" || return 1
	if [ "$DISABLE_QUIC" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "udp dport 443 reject"
	fi
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
}

nft_emit_policy_rules() {
	case "${POLICY_MODE:-direct-first}" in
		direct-first) nft_emit_direct_first_policy_rules ;;
		proxy-first) nft_emit_proxy_first_policy_rules ;;
		*) return 1 ;;
	esac
}

nft_apply_policy() {
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"
	local direct_list_file="${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}"

	ensure_dir "$PKG_TMP_DIR"
	NFT_BATCH_FILE="$(mktemp "$PKG_TMP_DIR/nft.XXXXXX")" || return 1
	NFT_PROXY_DST_COUNT=0
	NFT_PROXY_SRC_COUNT=0
	NFT_DIRECT_DST_COUNT=0
	NFT_PROXY_DST_SET_COUNT=0
	NFT_PROXY_SRC_SET_COUNT=0
	NFT_DIRECT_DST_SET_COUNT=0

	nft_emit_delete_existing_tables || {
		nft_cleanup_batch_file
		return 1
	}

	nft_emit_base_table || {
		nft_cleanup_batch_file
		return 1
	}
	nft_emit_interface_set || {
		nft_cleanup_batch_file
		return 1
	}
	case "${POLICY_MODE:-direct-first}" in
		direct-first)
			nft_emit_policy_file_to_set "$dst_list_file" "$NFT_PROXY_DST_SET" NFT_PROXY_DST_COUNT NFT_PROXY_DST_SET_COUNT || {
				nft_cleanup_batch_file
				return 1
			}
			nft_emit_policy_file_to_set "$src_list_file" "$NFT_PROXY_SRC_SET" NFT_PROXY_SRC_COUNT NFT_PROXY_SRC_SET_COUNT || {
				nft_cleanup_batch_file
				return 1
			}
			;;
		proxy-first)
			nft_emit_policy_file_to_set "$direct_list_file" "$NFT_DIRECT_DST_SET" NFT_DIRECT_DST_COUNT NFT_DIRECT_DST_SET_COUNT || {
				nft_cleanup_batch_file
				return 1
			}
			;;
		*)
			nft_cleanup_batch_file
			return 1
			;;
	esac
	nft_emit_policy_rules || {
		nft_cleanup_batch_file
		return 1
	}

	if ! nft -f "$NFT_BATCH_FILE"; then
		nft_cleanup_batch_file
		return 1
	fi

	nft_cleanup_batch_file
	log "Applied nft policy table $NFT_TABLE_NAME"
	return 0
}

nft_remove_policy() {
	local table table_state=1 removed=0

	for table in "$NFT_TABLE_NAME" ${NFT_LEGACY_TABLE_NAMES:-}; do
		nft_table_exists_named "$table"
		table_state=$?
		case "$table_state" in
			0)
				nft_delete_table_named_if_exists "$table" || return 1
				log "Removed nft policy table $table"
				removed=1
				;;
			1)
				:
				;;
			*)
				return 1
				;;
		esac
	done

	[ "$removed" -eq 1 ] || log "nft policy table $NFT_TABLE_NAME already clean"

	return 0
}

policy_route_state_read() {
	local line=""

	[ -f "$ROUTE_STATE_FILE" ] || return 1

	ROUTE_TABLE_ID_EFFECTIVE=""
	ROUTE_RULE_PRIORITY_EFFECTIVE=""
	while IFS= read -r line; do
		case "$line" in
			ROUTE_TABLE_ID=*)
				[ -z "$ROUTE_TABLE_ID_EFFECTIVE" ] && ROUTE_TABLE_ID_EFFECTIVE="${line#ROUTE_TABLE_ID=}"
				;;
			ROUTE_RULE_PRIORITY=*)
				[ -z "$ROUTE_RULE_PRIORITY_EFFECTIVE" ] && ROUTE_RULE_PRIORITY_EFFECTIVE="${line#ROUTE_RULE_PRIORITY=}"
				;;
		esac
	done < "$ROUTE_STATE_FILE"

	is_valid_route_table_id "$ROUTE_TABLE_ID_EFFECTIVE" || return 1
	is_valid_route_rule_priority "$ROUTE_RULE_PRIORITY_EFFECTIVE" || return 1
	return 0
}

policy_route_table_id_in_use() {
	local route_table_id="$1"
	local table_state=1

	grep -qE "^[[:space:]]*${route_table_id}[[:space:]]+" "${ROUTE_TABLES_FILE:-/etc/iproute2/rt_tables}" 2>/dev/null && return 0
	if policy_route_table_has_entries "$route_table_id"; then
		table_state=0
	else
		table_state=$?
	fi
	case "$table_state" in
		0) return 0 ;;
		1) return 1 ;;
		*) return 0 ;;
	esac
}

policy_route_priority_in_use() {
	local route_rule_priority="$1"
	local rules_output=""

	rules_output="$(ip rule show 2>/dev/null)" || return 0
	printf '%s\n' "$rules_output" | awk -F: -v priority="$route_rule_priority" '$1 + 0 == priority { found=1 } END { exit(found ? 0 : 1) }'
}

policy_route_priority_conflicts() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rules_output="" mark="" mark_hex="" mark_dec=""

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 2

	mark="$NFT_INTERCEPT_MARK"
	mark_hex="$(printf '0x%x' "$(( NFT_INTERCEPT_MARK ))")"
	mark_dec="$(( NFT_INTERCEPT_MARK ))"
	rules_output="$(ip rule show 2>/dev/null)" || return 2
	printf '%s\n' "$rules_output" | awk -v priority="$route_rule_priority" -v table="$route_table_id" -v mark="$mark" -v mark_hex="$mark_hex" -v mark_dec="$mark_dec" '
		$1 == priority ":" {
			table_match = (index($0, " lookup " table) || index($0, " table " table))
			mark_match = (index($0, " fwmark " mark "/" mark) || index($0, " fwmark " mark_hex "/" mark_hex) || index($0, " fwmark " mark_dec "/" mark_dec))
			if (table_match && mark_match) {
				next
			}
			conflict=1
		}
		END { exit(conflict ? 0 : 1) }
	'
}

policy_route_state_can_reuse() {
	local table_state=1 priority_state=1

	if ! policy_route_state_read; then
		return 1
	fi

	if policy_route_table_has_foreign_entries "$ROUTE_TABLE_ID_EFFECTIVE"; then
		table_state=0
	else
		table_state=$?
	fi
	case "$table_state" in
		0)
			warn "Route table $ROUTE_TABLE_ID_EFFECTIVE has foreign entries; selecting new table"
			return 1
			;;
		1)
			:
			;;
		*)
			return 2
			;;
	esac

	if policy_route_priority_conflicts "$ROUTE_TABLE_ID_EFFECTIVE" "$ROUTE_RULE_PRIORITY_EFFECTIVE"; then
		priority_state=0
	else
		priority_state=$?
	fi
	case "$priority_state" in
		0)
			warn "Route rule priority $ROUTE_RULE_PRIORITY_EFFECTIVE is occupied; selecting new priority"
			return 1
			;;
		1)
			return 0
			;;
		*)
			return 2
			;;
	esac
}

policy_route_drop_saved_state() {
	local route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
	local route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	policy_route_teardown_ids "$route_table_id" "$route_rule_priority" || return 1
	rm -f "$ROUTE_STATE_FILE"
}

policy_route_find_free_table_id() {
	local route_table_id="$ROUTE_TABLE_ID_AUTO_MIN"

	while [ "$route_table_id" -le "$ROUTE_TABLE_ID_AUTO_MAX" ]; do
		if ! policy_route_table_id_in_use "$route_table_id"; then
			printf '%s\n' "$route_table_id"
			return 0
		fi
		route_table_id=$((route_table_id + 1))
	done

	err "Unable to find free route table id"
	return 1
}

policy_route_find_free_priority() {
	local route_rule_priority="$ROUTE_RULE_PRIORITY_AUTO_MIN"

	while [ "$route_rule_priority" -le "$ROUTE_RULE_PRIORITY_AUTO_MAX" ]; do
		if ! policy_route_priority_in_use "$route_rule_priority"; then
			printf '%s\n' "$route_rule_priority"
			return 0
		fi
		route_rule_priority=$((route_rule_priority + 1))
	done

	err "Unable to find free route rule priority"
	return 1
}

policy_route_resolve_ids() {
	local route_table_id="$MIHOMO_ROUTE_TABLE_ID"
	local route_rule_priority="$MIHOMO_ROUTE_RULE_PRIORITY"
	local state_rc=1

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		if policy_route_state_can_reuse; then
			state_rc=0
		else
			state_rc=$?
		fi
		case "$state_rc" in
			0)
				[ -n "$route_table_id" ] || route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
				[ -n "$route_rule_priority" ] || route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
				;;
			2)
				return 1
				;;
		esac
	fi

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		if policy_route_state_read; then
			policy_route_drop_saved_state || return 1
		fi
	fi

	[ -n "$route_table_id" ] || route_table_id="$(policy_route_find_free_table_id)" || return 1
	[ -n "$route_rule_priority" ] || route_rule_priority="$(policy_route_find_free_priority)" || return 1

	ROUTE_TABLE_ID_RESOLVED="$route_table_id"
	ROUTE_RULE_PRIORITY_RESOLVED="$route_rule_priority"
}

policy_route_resolve_table_id() {
	local route_table_id
	local state_rc=1

	if [ -n "$MIHOMO_ROUTE_TABLE_ID" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_TABLE_ID"
		return 0
	fi

	if policy_route_state_can_reuse; then
		state_rc=0
	else
		state_rc=$?
	fi
	case "$state_rc" in
		0)
			printf '%s\n' "$ROUTE_TABLE_ID_EFFECTIVE"
			return 0
			;;
		2)
			return 1
			;;
	esac

	if policy_route_state_read; then
		policy_route_drop_saved_state || return 1
	fi

	policy_route_find_free_table_id
}

policy_route_resolve_priority() {
	local route_rule_priority
	local state_rc=1

	if [ -n "$MIHOMO_ROUTE_RULE_PRIORITY" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_RULE_PRIORITY"
		return 0
	fi

	if policy_route_state_can_reuse; then
		state_rc=0
	else
		state_rc=$?
	fi
	case "$state_rc" in
		0)
			printf '%s\n' "$ROUTE_RULE_PRIORITY_EFFECTIVE"
			return 0
			;;
		2)
			return 1
			;;
	esac

	if policy_route_state_read; then
		policy_route_drop_saved_state || return 1
	fi

	policy_route_find_free_priority
}

policy_route_teardown_ids() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local route_state=1

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	have_command ip || return 1

	policy_route_delete_rule "$route_table_id" "$route_rule_priority" || return 1
	policy_route_delete_managed_route "$route_table_id" || return 1
	if policy_route_managed_route_exists "$route_table_id"; then
		route_state=0
	else
		route_state=$?
	fi
	case "$route_state" in
		0)
			return 1
			;;
		1)
			:
			;;
		*)
			return 1
			;;
	esac
	return 0
}

policy_route_rule_exists() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rules_output="" mark="" mark_hex="" mark_dec=""

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 2

	mark="$NFT_INTERCEPT_MARK"
	mark_hex="$(printf '0x%x' "$(( NFT_INTERCEPT_MARK ))")"
	mark_dec="$(( NFT_INTERCEPT_MARK ))"
	rules_output="$(ip rule show 2>/dev/null)" || return 2
	printf '%s\n' "$rules_output" | awk -v priority="$route_rule_priority" -v table="$route_table_id" -v mark="$mark" -v mark_hex="$mark_hex" -v mark_dec="$mark_dec" '
		$1 == priority ":" &&
		(index($0, " lookup " table) || index($0, " table " table)) &&
		(index($0, " fwmark " mark "/" mark) || index($0, " fwmark " mark_hex "/" mark_hex) || index($0, " fwmark " mark_dec "/" mark_dec)) { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

policy_route_show_table() {
	local route_table_id="$1"
	local route_output="" route_rc=0

	if route_output="$(ip route show table "$route_table_id" 2>&1)"; then
		printf '%s\n' "$route_output"
		return 0
	else
		route_rc=$?
	fi

	case "$route_output" in
		*"FIB table does not exist"*|*"No such file"*|*"does not exist"*)
			return 0
			;;
	esac
	return "$route_rc"
}

policy_route_table_has_entries() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | grep -q .
}

policy_route_managed_route_exists() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | awk '
		$1 == "local" && ($2 == "0.0.0.0/0" || $2 == "default") {
			for (i = 3; i <= NF; i++) {
				if ($i == "dev" && (i + 1) <= NF && $(i + 1) == "lo") {
					found=1
				}
			}
		}
		END { exit(found ? 0 : 1) }
	'
}

policy_route_table_has_foreign_entries() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(policy_route_show_table "$route_table_id")" || return 2
	printf '%s\n' "$route_output" | awk '
		NF == 0 { next }
		$1 == "local" && ($2 == "0.0.0.0/0" || $2 == "default") {
			managed=0
			for (i = 3; i <= NF; i++) {
				if ($i == "dev" && (i + 1) <= NF && $(i + 1) == "lo") {
					managed=1
				}
			}
			if (managed) {
				next
			}
		}
		{ foreign=1 }
		END { exit(foreign ? 0 : 1) }
	'
}

policy_route_delete_managed_route() {
	local route_table_id="$1"
	local route_state=1

	[ -n "$route_table_id" ] || return 0

	if policy_route_managed_route_exists "$route_table_id"; then
		route_state=0
	else
		route_state=$?
	fi
	case "$route_state" in
		0)
			:
			;;
		1)
			return 0
			;;
		*)
			return 1
			;;
	esac

	while ip route del local 0.0.0.0/0 dev lo table "$route_table_id" 2>/dev/null; do :; done
	if policy_route_managed_route_exists "$route_table_id"; then
		route_state=0
	else
		route_state=$?
	fi
	[ "$route_state" -eq 1 ]
}

policy_route_delete_rule() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rule_state=1

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0

	if policy_route_rule_exists "$route_table_id" "$route_rule_priority"; then
		rule_state=0
	else
		rule_state=$?
	fi
	case "$rule_state" in
		0)
			:
			;;
		1)
			return 0
			;;
		*)
			return 1
			;;
	esac

	while ip rule del fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$route_table_id" priority "$route_rule_priority" 2>/dev/null; do :; done
	if policy_route_rule_exists "$route_table_id" "$route_rule_priority"; then
		rule_state=0
	else
		rule_state=$?
	fi
	[ "$rule_state" -eq 1 ]
}

policy_route_setup() {
	local route_table_id route_rule_priority
	local table_state=1 priority_state=1

	ROUTE_TABLE_ID_RESOLVED=""
	ROUTE_RULE_PRIORITY_RESOLVED=""
	policy_route_resolve_ids || return 1
	route_table_id="$ROUTE_TABLE_ID_RESOLVED"
	route_rule_priority="$ROUTE_RULE_PRIORITY_RESOLVED"

	if policy_route_table_has_foreign_entries "$route_table_id"; then
		table_state=0
	else
		table_state=$?
	fi
	case "$table_state" in
		0)
			err "Route table $route_table_id has foreign entries"
			return 1
			;;
		1)
			:
			;;
		*)
			return 1
			;;
	esac

	if policy_route_priority_conflicts "$route_table_id" "$route_rule_priority"; then
		priority_state=0
	else
		priority_state=$?
	fi
	case "$priority_state" in
		0)
			err "Route rule priority $route_rule_priority is occupied"
			return 1
			;;
		1)
			:
			;;
		*)
			return 1
			;;
	esac

	policy_route_delete_rule "$route_table_id" "$route_rule_priority" || return 1
	ip route replace local 0.0.0.0/0 dev lo table "$route_table_id" 2>/dev/null || return 1
	ip rule add fwmark "$NFT_INTERCEPT_MARK"/"$NFT_INTERCEPT_MARK" table "$route_table_id" priority "$route_rule_priority" 2>/dev/null || {
		policy_route_teardown_ids "$route_table_id" "$route_rule_priority"
		return 1
	}

	ensure_dir "$PKG_STATE_DIR"
	if ! printf 'ROUTE_TABLE_ID=%s\nROUTE_RULE_PRIORITY=%s\n' "$route_table_id" "$route_rule_priority" > "$ROUTE_STATE_FILE"; then
		policy_route_teardown_ids "$route_table_id" "$route_rule_priority"
		return 1
	fi
	log "Installed policy routing for mark $NFT_INTERCEPT_MARK with table $route_table_id priority $route_rule_priority"
	return 0
}

policy_route_cleanup() {
	local route_table_id="" route_rule_priority=""
	local rule_state=1 route_state=1 had_live_state=0

	if policy_route_state_read; then
		route_table_id="$ROUTE_TABLE_ID_EFFECTIVE"
		route_rule_priority="$ROUTE_RULE_PRIORITY_EFFECTIVE"
	else
		route_table_id="$MIHOMO_ROUTE_TABLE_ID"
		route_rule_priority="$MIHOMO_ROUTE_RULE_PRIORITY"
	fi

	if [ -z "$route_table_id" ] || [ -z "$route_rule_priority" ]; then
		rm -f "$ROUTE_STATE_FILE"
		log "Policy routing for mark $NFT_INTERCEPT_MARK already clean"
		return 0
	fi

	if policy_route_rule_exists "$route_table_id" "$route_rule_priority"; then
		rule_state=0
	else
		rule_state=$?
	fi
	case "$rule_state" in
		0) had_live_state=1 ;;
		1) ;;
		*) return 1 ;;
	esac

	if policy_route_managed_route_exists "$route_table_id"; then
		route_state=0
	else
		route_state=$?
	fi
	case "$route_state" in
		0) had_live_state=1 ;;
		1) ;;
		*) return 1 ;;
	esac

	policy_route_teardown_ids "$route_table_id" "$route_rule_priority" || return 1

	rm -f "$ROUTE_STATE_FILE"
	if [ "$had_live_state" -eq 1 ]; then
		log "Removed policy routing for mark $NFT_INTERCEPT_MARK"
	else
		log "Policy routing for mark $NFT_INTERCEPT_MARK already clean"
	fi
	return 0
}
