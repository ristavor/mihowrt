#!/bin/ash

# Delete a managed table if it exists; missing table is a clean state.
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

# Delete a table that caller already knows is present, then verify it is gone.
nft_delete_present_table_named() {
	local table="$1"
	local table_state=1

	nft delete table inet "$table" >/dev/null 2>&1 || return 1
	nft_table_exists_named "$table"
	table_state=$?
	[ "$table_state" -eq 1 ]
}

# Read inet table list once for callers that need repeated lookups.
nft_list_tables_output() {
	have_command nft || return 2
	nft list tables inet 2>/dev/null
}

# Test for one table name inside nft list output.
nft_table_list_has_named() {
	local table="$1"
	local tables_output="$2"

	printf '%s\n' "$tables_output" | awk -v table="$table" '
		$1 == "table" && $2 == "inet" && $3 == table { found=1 }
		END { exit(found ? 0 : 1) }
	'
}

# Remove current MihoWRT table.
nft_delete_table_if_exists() {
	nft_delete_table_named_if_exists "$NFT_TABLE_NAME"
}

# True when a named inet table exists.
nft_table_exists_named() {
	local table="$1"
	local tables_output=""

	tables_output="$(nft_list_tables_output)" || return 2
	nft_table_list_has_named "$table" "$tables_output"
}

nft_table_exists() {
	nft_table_exists_named "$NFT_TABLE_NAME"
}

nft_chain_exists() {
	local chain="$1"

	have_command nft || return 2
	nft list chain inet "$NFT_TABLE_NAME" "$chain" >/dev/null 2>&1
}

# Batch starts by deleting old managed tables so rules never duplicate.
nft_emit_delete_existing_tables() {
	local table tables_output

	tables_output="$(nft_list_tables_output)" || return 1
	for table in "$NFT_TABLE_NAME" ${NFT_LEGACY_TABLE_NAMES:-}; do
		nft_table_list_has_named "$table" "$tables_output" || continue
		nft_emit_line "delete table inet $table"
	done
}

# Append one line to the current nft batch file.
nft_emit_line() {
	printf '%s\n' "$1" >>"$NFT_BATCH_FILE"
}

# Remove successful batch temp file.
nft_cleanup_batch_file() {
	[ -n "${NFT_BATCH_FILE:-}" ] && rm -f "$NFT_BATCH_FILE"
}

# Remove failed batch temp file and return failure.
nft_abort_batch() {
	nft_cleanup_batch_file
	return 1
}

# Emit large set payload in chunks instead of one huge nft line.
nft_emit_elements_chunk() {
	local set_name="$1"
	local chunk="$2"

	[ -n "$chunk" ] || return 0
	nft_emit_line "add element inet $NFT_TABLE_NAME $set_name { $chunk }"
}

# Quote interface names for nft ifname set elements.
nft_quote_ifname() {
	local iface="$1"

	is_valid_iface_name "$iface" || return 1
	printf '"%s"' "$iface"
}

# Load IP/CIDR-only policy entries into an interval set. Port-qualified entries
# are skipped here and emitted later as explicit rules.
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

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
		'' | '#'*) continue ;;
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
	done <"$file"

	nft_emit_elements_chunk "$set_name" "$chunk" || return 1
	eval "$total_count_var=$total_count"
	eval "$set_count_var=$set_count"
	log "Loaded $set_count unscoped and $scoped_count port-scoped entries, skipped $invalid_count invalid entries for set $set_name"
	return 0
}

nft_policy_file_port_scoped_count() {
	local file="$1"
	local count=0
	local line

	[ -f "$file" ] || {
		printf '0\n'
		return 0
	}

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
		'' | '#'*) continue ;;
		esac
		is_policy_entry "$line" || continue
		policy_entry_has_ports "$line" || continue
		count=$((count + 1))
	done <"$file"

	printf '%s\n' "$count"
}

nft_policy_file_unscoped_count() {
	local file="$1"
	local count=0
	local line

	[ -f "$file" ] || {
		printf '0\n'
		return 0
	}

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
		'' | '#'*) continue ;;
		esac
		is_policy_entry "$line" || continue
		policy_entry_has_ports "$line" && continue
		count=$((count + 1))
	done <"$file"

	printf '%s\n' "$count"
}

# Compatibility helper for plain IPv4 list files.
nft_emit_ipv4_file_to_set() {
	local file="$1"
	local set_name="$2"
	local count_var="$3"
	local total_count=0

	nft_emit_policy_file_to_set "$file" "$set_name" total_count "$count_var"
}

# Emit table, sets, base chains, and local IPv4 exclusions.
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
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_OUTPUT"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING"
	nft_emit_line "add chain inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT"
}

# Populate selected ingress interfaces.
nft_emit_interface_set() {
	local iface quoted_iface

	for iface in $SOURCE_INTERFACES; do
		quoted_iface="$(nft_quote_ifname "$iface")" || return 1
		nft_emit_line "add element inet $NFT_TABLE_NAME $NFT_IFACE_SET { $quoted_iface }"
	done
}

# Emit one nft rule into the current batch.
nft_emit_rule() {
	local chain="$1"
	local expr="$2"

	nft_emit_line "add rule inet $NFT_TABLE_NAME $chain $expr"
}

# Emit explicit rules for port-qualified policy entries.
nft_emit_policy_port_rules() {
	local file="$1"
	local field="$2"
	local chain="$3"
	local action="$4"
	local line addr ports ports_expr addr_expr

	[ -f "$file" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
		'' | '#'*) continue ;;
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
	done <"$file"
}

# Emit QUIC reject rules only for port-qualified entries that include UDP/443.
nft_emit_policy_quic_port_rejects() {
	local file="$1"
	local field="$2"
	local chain="$3"
	local line addr ports addr_expr

	[ -f "$file" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		line="$(trim "$line")"
		case "$line" in
		'' | '#'*) continue ;;
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
	done <"$file"
}

nft_emit_mark_port_chain_rules() {
	local file="$1"
	local field="$2"
	local chain="$3"

	if [ "$DISABLE_QUIC" = "1" ]; then
		nft_emit_policy_quic_port_rejects "$file" "$field" "$chain" || return 1
	fi
	nft_emit_policy_port_rules "$file" "$field" "$chain" "meta mark set $NFT_INTERCEPT_MARK"
}

nft_emit_return_port_chain_rules() {
	local file="$1"
	local field="$2"
	local chain="$3"

	nft_emit_policy_port_rules "$file" "$field" "$chain" "return"
}

nft_emit_direct_first_port_chains() {
	local dst_list_file="$1"
	local src_list_file="$2"

	if [ "${NFT_PROXY_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_mark_port_chain_rules "$dst_list_file" "daddr" "$NFT_CHAIN_PROXY_DST_PORTS_PREROUTING" || return 1
		nft_emit_mark_port_chain_rules "$dst_list_file" "daddr" "$NFT_CHAIN_PROXY_DST_PORTS_OUTPUT" || return 1
	fi
	if [ "${NFT_PROXY_SRC_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_mark_port_chain_rules "$src_list_file" "saddr" "$NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING" || return 1
	fi
}

nft_emit_proxy_first_port_chains() {
	local direct_list_file="$1"

	if [ "${NFT_DIRECT_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_return_port_chain_rules "$direct_list_file" "daddr" "$NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING" || return 1
		nft_emit_return_port_chain_rules "$direct_list_file" "daddr" "$NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT" || return 1
	fi
}

# Shared prerouting setup: DNS hijack, interface guard, local return, loop guard.
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

# Shared TPROXY rule and output-chain loop guards.
nft_emit_common_proxy_rules() {
	nft_emit_rule "$NFT_CHAIN_PROXY" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"

	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $MIHOMO_ROUTING_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta mark $NFT_INTERCEPT_MARK return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta l4proto { tcp, udp } th dport $MIHOMO_TPROXY_PORT return"
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_LOCALV4_SET return"
}

# direct-first marks only listed destinations/sources and fake-ip traffic.
nft_emit_direct_first_policy_rules() {
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"

	nft_emit_direct_first_port_chains "$dst_list_file" "$src_list_file" || return 1
	nft_emit_common_policy_start

	if [ "$DISABLE_QUIC" = "1" ]; then
		if [ "$CATCH_FAKEIP" = "1" ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET udp dport 443 reject"
		fi
		if [ "${NFT_PROXY_SRC_SET_COUNT:-0}" -gt 0 ]; then
			nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET udp dport 443 reject"
		fi
	fi

	if [ "${NFT_PROXY_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "jump $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING"
	fi
	if [ "${NFT_PROXY_SRC_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "jump $NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING"
	fi
	if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	if [ "${NFT_PROXY_SRC_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip saddr @$NFT_PROXY_SRC_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
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
	fi

	if [ "${NFT_PROXY_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "jump $NFT_CHAIN_PROXY_DST_PORTS_OUTPUT"
	fi
	if [ "${NFT_PROXY_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_PROXY_DST_SET meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
	if [ "$CATCH_FAKEIP" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
	fi
}

# proxy-first marks all non-local TCP/UDP unless direct_dst returns it early.
nft_emit_proxy_first_policy_rules() {
	local direct_list_file="${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}"

	nft_emit_proxy_first_port_chains "$direct_list_file" || return 1
	nft_emit_common_policy_start
	if [ "${NFT_DIRECT_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "ip daddr @$NFT_DIRECT_DST_SET return"
	fi
	if [ "${NFT_DIRECT_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "jump $NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING"
	fi
	if [ "$DISABLE_QUIC" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "udp dport 443 reject"
	fi
	nft_emit_rule "$NFT_CHAIN_PREROUTING_POLICY" "meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"

	nft_emit_common_proxy_rules
	if [ "${NFT_DIRECT_DST_SET_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "ip daddr @$NFT_DIRECT_DST_SET return"
	fi
	if [ "${NFT_DIRECT_DST_PORT_COUNT:-0}" -gt 0 ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "jump $NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT"
	fi
	if [ "$DISABLE_QUIC" = "1" ]; then
		nft_emit_rule "$NFT_CHAIN_OUTPUT" "udp dport 443 reject"
	fi
	nft_emit_rule "$NFT_CHAIN_OUTPUT" "meta l4proto { tcp, udp } meta mark set $NFT_INTERCEPT_MARK"
}

# Dispatch rules for current policy mode.
nft_emit_policy_rules() {
	case "${POLICY_MODE:-direct-first}" in
	direct-first) nft_emit_direct_first_policy_rules ;;
	proxy-first) nft_emit_proxy_first_policy_rules ;;
	*) return 1 ;;
	esac
}

# Build and apply one complete nft batch.
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
		NFT_PROXY_DST_PORT_COUNT="$(nft_policy_file_port_scoped_count "$dst_list_file")" || return 1
		NFT_PROXY_SRC_PORT_COUNT="$(nft_policy_file_port_scoped_count "$src_list_file")" || return 1
		;;
	proxy-first)
		nft_emit_policy_file_to_set "$direct_list_file" "$NFT_DIRECT_DST_SET" NFT_DIRECT_DST_COUNT NFT_DIRECT_DST_SET_COUNT || return 1
		NFT_DIRECT_DST_PORT_COUNT="$(nft_policy_file_port_scoped_count "$direct_list_file")" || return 1
		;;
	*)
		return 1
		;;
	esac
	nft_emit_policy_rules || return 1
	nft -f "$NFT_BATCH_FILE"
}

# Public nft apply entrypoint used by runtime orchestration.
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
	NFT_PROXY_DST_PORT_COUNT=0
	NFT_PROXY_SRC_PORT_COUNT=0
	NFT_DIRECT_DST_PORT_COUNT=0

	if ! nft_apply_policy_batch "$dst_list_file" "$src_list_file" "$direct_list_file"; then
		nft_abort_batch
		return 1
	fi

	nft_cleanup_batch_file
	log "Applied nft policy table $NFT_TABLE_NAME"
	return 0
}

nft_policy_component_set_name() {
	case "$1" in
	proxy_dst) printf '%s\n' "$NFT_PROXY_DST_SET" ;;
	proxy_src) printf '%s\n' "$NFT_PROXY_SRC_SET" ;;
	direct_dst) printf '%s\n' "$NFT_DIRECT_DST_SET" ;;
	*) return 1 ;;
	esac
}

nft_policy_component_file() {
	case "$1" in
	proxy_dst) printf '%s\n' "${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}" ;;
	proxy_src) printf '%s\n' "${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}" ;;
	direct_dst) printf '%s\n' "${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}" ;;
	*) return 1 ;;
	esac
}

nft_policy_component_snapshot_file() {
	case "$1" in
	proxy_dst) runtime_snapshot_dst_file ;;
	proxy_src) runtime_snapshot_src_file ;;
	direct_dst) runtime_snapshot_direct_file ;;
	*) return 1 ;;
	esac
}

nft_policy_component_port_chains() {
	case "$1" in
	proxy_dst) printf '%s\n%s\n' "$NFT_CHAIN_PROXY_DST_PORTS_PREROUTING" "$NFT_CHAIN_PROXY_DST_PORTS_OUTPUT" ;;
	proxy_src) printf '%s\n' "$NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING" ;;
	direct_dst) printf '%s\n%s\n' "$NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING" "$NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT" ;;
	*) return 1 ;;
	esac
}

nft_policy_component_fast_update_supported() {
	local component="$1"
	local old_file="" new_file="" old_ports=0 new_ports=0 old_unscoped=0 new_unscoped=0 chain=""

	old_file="$(nft_policy_component_snapshot_file "$component")" || return 1
	new_file="$(nft_policy_component_file "$component")" || return 1
	old_ports="$(nft_policy_file_port_scoped_count "$old_file")" || return 1
	new_ports="$(nft_policy_file_port_scoped_count "$new_file")" || return 1
	old_unscoped="$(nft_policy_file_unscoped_count "$old_file")" || return 1
	new_unscoped="$(nft_policy_file_unscoped_count "$new_file")" || return 1

	if { [ "$old_ports" -eq 0 ] && [ "$new_ports" -gt 0 ]; } ||
		{ [ "$old_ports" -gt 0 ] && [ "$new_ports" -eq 0 ]; }; then
		return 1
	fi
	if { [ "$old_unscoped" -eq 0 ] && [ "$new_unscoped" -gt 0 ]; } ||
		{ [ "$old_unscoped" -gt 0 ] && [ "$new_unscoped" -eq 0 ]; }; then
		return 1
	fi

	if [ "$new_ports" -gt 0 ]; then
		while IFS= read -r chain; do
			[ -n "$chain" ] || continue
			nft_chain_exists "$chain" || return 1
		done <<EOF
$(nft_policy_component_port_chains "$component")
EOF
	fi

	return 0
}

nft_emit_flush_policy_set() {
	local set_name="$1"

	nft_emit_line "flush set inet $NFT_TABLE_NAME $set_name"
}

nft_emit_policy_component_port_update() {
	local component="$1"
	local file="$2"

	case "$component" in
	proxy_dst)
		nft_emit_line "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_PREROUTING"
		nft_emit_line "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_DST_PORTS_OUTPUT"
		nft_emit_mark_port_chain_rules "$file" "daddr" "$NFT_CHAIN_PROXY_DST_PORTS_PREROUTING" || return 1
		nft_emit_mark_port_chain_rules "$file" "daddr" "$NFT_CHAIN_PROXY_DST_PORTS_OUTPUT" || return 1
		;;
	proxy_src)
		nft_emit_line "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING"
		nft_emit_mark_port_chain_rules "$file" "saddr" "$NFT_CHAIN_PROXY_SRC_PORTS_PREROUTING" || return 1
		;;
	direct_dst)
		nft_emit_line "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING"
		nft_emit_line "flush chain inet $NFT_TABLE_NAME $NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT"
		nft_emit_return_port_chain_rules "$file" "daddr" "$NFT_CHAIN_DIRECT_DST_PORTS_PREROUTING" || return 1
		nft_emit_return_port_chain_rules "$file" "daddr" "$NFT_CHAIN_DIRECT_DST_PORTS_OUTPUT" || return 1
		;;
	*)
		return 1
		;;
	esac
}

nft_emit_policy_component_update() {
	local component="$1"
	local file="" set_name="" total_var="" set_count_var="" port_count=0

	file="$(nft_policy_component_file "$component")" || return 1
	set_name="$(nft_policy_component_set_name "$component")" || return 1
	case "$component" in
	proxy_dst) total_var=NFT_FAST_PROXY_DST_COUNT; set_count_var=NFT_FAST_PROXY_DST_SET_COUNT ;;
	proxy_src) total_var=NFT_FAST_PROXY_SRC_COUNT; set_count_var=NFT_FAST_PROXY_SRC_SET_COUNT ;;
	direct_dst) total_var=NFT_FAST_DIRECT_DST_COUNT; set_count_var=NFT_FAST_DIRECT_DST_SET_COUNT ;;
	*) return 1 ;;
	esac

	nft_emit_flush_policy_set "$set_name"
	nft_emit_policy_file_to_set "$file" "$set_name" "$total_var" "$set_count_var" || return 1

	port_count="$(nft_policy_file_port_scoped_count "$file")" || return 1
	if [ "$port_count" -gt 0 ]; then
		nft_emit_policy_component_port_update "$component" "$file" || return 1
	fi
}

nft_update_policy_components_fast() {
	local components="$1"
	local component=""

	ensure_dir "$PKG_TMP_DIR"
	NFT_BATCH_FILE="$(mktemp "$PKG_TMP_DIR/nft-fast.XXXXXX")" || return 1

	for component in $components; do
		nft_emit_policy_component_update "$component" || {
			nft_abort_batch
			return 1
		}
	done

	if ! nft -f "$NFT_BATCH_FILE"; then
		nft_abort_batch
		return 1
	fi

	nft_cleanup_batch_file
	log "Updated nft policy components: $components"
}

# Remove current and legacy managed nft tables during cleanup/recovery.
nft_remove_policy() {
	local table tables_output="" removed=0

	tables_output="$(nft_list_tables_output)" || return 1
	for table in "$NFT_TABLE_NAME" ${NFT_LEGACY_TABLE_NAMES:-}; do
		nft_table_list_has_named "$table" "$tables_output" || continue
		nft_delete_present_table_named "$table" || return 1
		log "Removed nft policy table $table"
		removed=1
	done

	[ "$removed" -eq 1 ] || log "nft policy table $NFT_TABLE_NAME already clean"

	return 0
}
