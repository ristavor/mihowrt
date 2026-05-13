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

	nft_delete_present_table_named "$table"
}

nft_delete_present_table_named() {
	local table="$1"
	local table_state=1

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

nft_abort_batch() {
	nft_cleanup_batch_file
	return 1
}

nft_emit_elements_chunk() {
	local set_name="$1"
	local chunk="$2"

	[ -n "$chunk" ] || return 0
	nft_emit_line "add element inet $NFT_TABLE_NAME $set_name { $chunk }"
}

nft_quote_ifname() {
	local iface="$1"

	is_valid_iface_name "$iface" || return 1
	printf '"%s"' "$iface"
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
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_IFACE_SET { type ifname; }"
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
	local iface quoted_iface

	for iface in $SOURCE_INTERFACES; do
		quoted_iface="$(nft_quote_ifname "$iface")" || return 1
		nft_emit_line "add element inet $NFT_TABLE_NAME $NFT_IFACE_SET { $quoted_iface }"
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
		nft_emit_rule "$chain" "$addr_expr meta l4proto { tcp, udp } th dport $ports_expr $action"
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
		nft_emit_rule "$NFT_CHAIN_DNS_HIJACK" "iifname @$NFT_IFACE_SET ip daddr != @$NFT_LOCALV4_SET meta l4proto { tcp, udp } th dport 53 redirect to :$dns_port"
	fi

	nft_emit_rule "$NFT_CHAIN_PREROUTING" "iifname @$NFT_IFACE_SET jump $NFT_CHAIN_PREROUTING_POLICY"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_LOCALV4_SET return"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta mark $NFT_INTERCEPT_MARK return"
	if [ "$DNS_HIJACK" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta l4proto { tcp, udp } th dport 53 return"
	fi
}

nft_emit_common_proxy_rules() {
	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"

	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $MIHOMO_ROUTING_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $NFT_INTERCEPT_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta l4proto { tcp, udp } th dport $MIHOMO_TPROXY_PORT return"
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

nft_apply_policy_batch() {
	local dst_list_file="$1"
	local src_list_file="$2"
	local direct_list_file="$3"

	nft_emit_delete_existing_tables || return 1
	nft_emit_base_table || return 1
	nft_emit_interface_set || return 1
	case "${POLICY_MODE:-direct-first}" in
		direct-first)
			nft_emit_policy_file_to_set "$dst_list_file" "$NFT_PROXY_DST_SET" NFT_PROXY_DST_COUNT NFT_PROXY_DST_SET_COUNT || return 1
			nft_emit_policy_file_to_set "$src_list_file" "$NFT_PROXY_SRC_SET" NFT_PROXY_SRC_COUNT NFT_PROXY_SRC_SET_COUNT || return 1
			;;
		proxy-first)
			nft_emit_policy_file_to_set "$direct_list_file" "$NFT_DIRECT_DST_SET" NFT_DIRECT_DST_COUNT NFT_DIRECT_DST_SET_COUNT || return 1
			;;
		*)
			return 1
			;;
	esac
	nft_emit_policy_rules || return 1
	nft -f "$NFT_BATCH_FILE"
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

	if ! nft_apply_policy_batch "$dst_list_file" "$src_list_file" "$direct_list_file"; then
		nft_abort_batch
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
				nft_delete_present_table_named "$table" || return 1
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
