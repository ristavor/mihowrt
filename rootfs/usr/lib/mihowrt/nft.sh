#!/bin/ash

nft_delete_table_if_exists() {
	local table_state=1

	nft_table_exists
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

	nft delete table inet "$NFT_TABLE_NAME" >/dev/null 2>&1 || return 1
	nft_table_exists
	table_state=$?
	[ "$table_state" -eq 1 ]
}

nft_table_exists() {
	local tables_output=""

	have_command nft || return 2
	tables_output="$(nft list tables inet 2>/dev/null)" || return 2
	printf '%s\n' "$tables_output" | awk -v table="$NFT_TABLE_NAME" '
		$1 == "table" && $2 == "inet" && $3 == table { found=1 }
		END { exit(found ? 0 : 1) }
	'
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

nft_emit_ipv4_file_to_set() {
	local file="$1"
	local set_name="$2"
	local count_var="$3"
	local chunk=""
	local count=0
	local valid_count=0
	local invalid_count=0
	local line

	[ -f "$file" ] || {
		eval "$count_var=0"
		return 0
	}

	while IFS= read -r line; do
		line="$(trim "$line")"
		case "$line" in
			''|'#'*) continue ;;
		esac

		if ! is_ipv4_cidr "$line"; then
			invalid_count=$((invalid_count + 1))
			warn "Skipping invalid IP/CIDR entry '$line' in $file"
			continue
		fi

		if [ -n "$chunk" ]; then
			chunk="$chunk,$line"
		else
			chunk="$line"
		fi

		count=$((count + 1))
		valid_count=$((valid_count + 1))

		if [ "$count" -ge 512 ]; then
			nft_emit_elements_chunk "$set_name" "$chunk" || return 1
			chunk=""
			count=0
		fi
	done < "$file"

	nft_emit_elements_chunk "$set_name" "$chunk" || return 1
	eval "$count_var=$valid_count"
	log "Loaded $valid_count valid and skipped $invalid_count invalid entries into set $set_name"
	return 0
}

nft_emit_base_table() {
	nft_emit_line "add table inet $NFT_TABLE_NAME"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_PROXY_DST_SET { type ipv4_addr; flags interval; auto-merge; }"
	nft_emit_line "add set inet $NFT_TABLE_NAME $NFT_PROXY_SRC_SET { type ipv4_addr; flags interval; auto-merge; }"
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

nft_emit_policy_rules() {
	local dns_port

	if [ "$DNS_HIJACK" = "1" ]; then
		dns_port="$(dns_listen_port "$MIHOMO_DNS_LISTEN")"
		nft_emit_rule "$NFT_CHAIN_DNS_HIJACK" "iifname @$NFT_IFACE_SET ip daddr != @$NFT_LOCALV4_SET udp dport 53 redirect to :$dns_port"
		nft_emit_rule "$NFT_CHAIN_DNS_HIJACK" "iifname @$NFT_IFACE_SET ip daddr != @$NFT_LOCALV4_SET tcp dport 53 redirect to :$dns_port"
	fi

	nft_emit_rule "$NFT_CHAIN_PREROUTING" "iifname @$NFT_IFACE_SET jump $NFT_CHAIN_PREROUTING_POLICY"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_LOCALV4_SET return"
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta mark $NFT_INTERCEPT_MARK return"

	if [ "$DISABLE_QUIC" = "1" ]; then
		if [ "$CATCH_FAKEIP" = "1" ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_DST_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_SRC_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET udp dport 443 reject"
		fi
	fi

	if [ "${NFT_PROXY_DST_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	if [ "${NFT_PROXY_SRC_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	if [ "$CATCH_FAKEIP" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi

	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto tcp tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"
	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto udp tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"

	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $MIHOMO_ROUTING_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $NFT_INTERCEPT_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "tcp dport $MIHOMO_TPROXY_PORT return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "udp dport $MIHOMO_TPROXY_PORT return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_LOCALV4_SET return"

	if [ "$DISABLE_QUIC" = "1" ]; then
		if [ "$CATCH_FAKEIP" = "1" ]; then
			nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_DST_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject"
		fi
	fi

	if [ "${NFT_PROXY_DST_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	if [ "$CATCH_FAKEIP" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
}

nft_apply_policy() {
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"

	ensure_dir "$PKG_TMP_DIR"
	NFT_BATCH_FILE="$(mktemp "$PKG_TMP_DIR/nft.XXXXXX")" || return 1
	NFT_PROXY_DST_COUNT=0
	NFT_PROXY_SRC_COUNT=0

	if nft_table_exists; then
		nft_emit_line "delete table inet $NFT_TABLE_NAME"
	fi

	nft_emit_base_table || {
		nft_cleanup_batch_file
		return 1
	}
	nft_emit_interface_set || {
		nft_cleanup_batch_file
		return 1
	}
	nft_emit_ipv4_file_to_set "$dst_list_file" "$NFT_PROXY_DST_SET" NFT_PROXY_DST_COUNT || {
		nft_cleanup_batch_file
		return 1
	}
	nft_emit_ipv4_file_to_set "$src_list_file" "$NFT_PROXY_SRC_SET" NFT_PROXY_SRC_COUNT || {
		nft_cleanup_batch_file
		return 1
	}
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
	local table_state=1

	nft_table_exists
	table_state=$?
	case "$table_state" in
		0)
			nft_delete_table_if_exists || return 1
			log "Removed nft policy table $NFT_TABLE_NAME"
			;;
		1)
			log "nft policy table $NFT_TABLE_NAME already clean"
			;;
		*)
			return 1
			;;
	esac

	return 0
}

policy_route_state_read() {
	[ -f "$ROUTE_STATE_FILE" ] || return 1
	ROUTE_TABLE_ID_EFFECTIVE="$(sed -n 's/^ROUTE_TABLE_ID=//p' "$ROUTE_STATE_FILE" 2>/dev/null | head -n1)"
	ROUTE_RULE_PRIORITY_EFFECTIVE="$(sed -n 's/^ROUTE_RULE_PRIORITY=//p' "$ROUTE_STATE_FILE" 2>/dev/null | head -n1)"
	is_valid_route_table_id "$ROUTE_TABLE_ID_EFFECTIVE" || return 1
	is_valid_route_rule_priority "$ROUTE_RULE_PRIORITY_EFFECTIVE" || return 1
	return 0
}

policy_route_table_id_in_use() {
	local route_table_id="$1"

	grep -qE "^[[:space:]]*${route_table_id}[[:space:]]+" /etc/iproute2/rt_tables 2>/dev/null && return 0
	ip route show table "$route_table_id" 2>/dev/null | grep -q . && return 0
	return 1
}

policy_route_priority_in_use() {
	local route_rule_priority="$1"

	ip rule show 2>/dev/null | awk -F: -v priority="$route_rule_priority" '$1 + 0 == priority { found=1 } END { exit(found ? 0 : 1) }'
}

policy_route_resolve_table_id() {
	local route_table_id

	if [ -n "$MIHOMO_ROUTE_TABLE_ID" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_TABLE_ID"
		return 0
	fi

	route_table_id="$ROUTE_TABLE_ID_AUTO_MIN"
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

policy_route_resolve_priority() {
	local route_rule_priority

	if [ -n "$MIHOMO_ROUTE_RULE_PRIORITY" ]; then
		printf '%s\n' "$MIHOMO_ROUTE_RULE_PRIORITY"
		return 0
	fi

	route_rule_priority="$ROUTE_RULE_PRIORITY_AUTO_MIN"
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

policy_route_teardown_ids() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local table_state=1

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0
	have_command ip || return 1

	policy_route_delete_rule "$route_table_id" "$route_rule_priority" || return 1
	policy_route_table_has_entries "$route_table_id"
	table_state=$?
	case "$table_state" in
		0)
			ip route flush table "$route_table_id" 2>/dev/null || return 1
			policy_route_table_has_entries "$route_table_id"
			table_state=$?
			[ "$table_state" -eq 1 ] || return 1
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
	local rules_output=""

	[ -n "$route_table_id" ] || return 1
	[ -n "$route_rule_priority" ] || return 1
	have_command ip || return 2

	rules_output="$(ip rule show 2>/dev/null)" || return 2
	printf '%s\n' "$rules_output" | awk -v priority="$route_rule_priority" -v table="$route_table_id" '
		$1 == priority ":" && (index($0, " lookup " table) || index($0, " table " table)) { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

policy_route_table_has_entries() {
	local route_table_id="$1"
	local route_output=""

	[ -n "$route_table_id" ] || return 1
	have_command ip || return 2
	route_output="$(ip route show table "$route_table_id" 2>/dev/null)" || return 2
	printf '%s\n' "$route_output" | grep -q .
}

policy_route_delete_rule() {
	local route_table_id="$1"
	local route_rule_priority="$2"
	local rule_state=1

	[ -n "$route_table_id" ] || return 0
	[ -n "$route_rule_priority" ] || return 0

	policy_route_rule_exists "$route_table_id" "$route_rule_priority"
	rule_state=$?
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
	policy_route_rule_exists "$route_table_id" "$route_rule_priority"
	rule_state=$?
	[ "$rule_state" -eq 1 ]
}

policy_route_setup() {
	local route_table_id route_rule_priority

	route_table_id="$(policy_route_resolve_table_id)" || return 1
	route_rule_priority="$(policy_route_resolve_priority)" || return 1

	policy_route_delete_rule "$route_table_id" "$route_rule_priority"
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
	local rule_state=1 table_state=1 had_live_state=0

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

	policy_route_rule_exists "$route_table_id" "$route_rule_priority"
	rule_state=$?
	case "$rule_state" in
		0) had_live_state=1 ;;
		1) ;;
		*) return 1 ;;
	esac

	policy_route_table_has_entries "$route_table_id"
	table_state=$?
	case "$table_state" in
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
