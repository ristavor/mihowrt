#!/bin/ash

# Main JSON snapshot of the runtime state that is currently applied.
runtime_snapshot_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/runtime.snapshot.json}"
}

# Effective always_proxy_dst list captured at apply time.
runtime_snapshot_dst_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_DST_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/always_proxy_dst.snapshot}"
}

runtime_snapshot_src_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_SRC_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/always_proxy_src.snapshot}"
}

runtime_snapshot_direct_file() {
	printf '%s\n' "${RUNTIME_SNAPSHOT_DIRECT_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/direct_dst.snapshot}"
}

# Snapshot is complete only when metadata and all list copies are present.
runtime_snapshot_exists() {
	[ -f "$(runtime_snapshot_file)" ] || return 1
	[ -f "$(runtime_snapshot_dst_file)" ] || return 1
	[ -f "$(runtime_snapshot_src_file)" ] || return 1
	[ -f "$(runtime_snapshot_direct_file)" ] || return 1
}

# Validate snapshot by parsing its status JSON.
runtime_snapshot_valid() {
	runtime_snapshot_exists || return 1
	runtime_snapshot_status_json >/dev/null 2>&1
}

# Remove all snapshot files after successful cleanup.
runtime_snapshot_clear() {
	rm -f "$(runtime_snapshot_file)" "$(runtime_snapshot_dst_file)" "$(runtime_snapshot_src_file)" "$(runtime_snapshot_direct_file)"
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
		: >"$dst" || return 1
	fi

	return 0
}

# Back up one existing snapshot component before replacing it.
runtime_snapshot_backup_file() {
	local src="$1"
	local backup="$2"

	[ -f "$src" ] || return 0
	cp -f "$src" "$backup" || return 1
	return 0
}

# Restore one snapshot component from its transaction backup.
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

# Restore all previous snapshot files after failed commit.
runtime_snapshot_restore_backups() {
	local snapshot_file="$1"
	local dst_snapshot="$2"
	local src_snapshot="$3"
	local direct_snapshot="$4"
	local snapshot_backup="$5"
	local dst_backup="$6"
	local src_backup="$7"
	local direct_backup="$8"

	runtime_snapshot_restore_file "$snapshot_file" "$snapshot_backup" || true
	runtime_snapshot_restore_file "$dst_snapshot" "$dst_backup" || true
	runtime_snapshot_restore_file "$src_snapshot" "$src_backup" || true
	runtime_snapshot_restore_file "$direct_snapshot" "$direct_backup" || true
	runtime_snapshot_cleanup_files "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup"
}

# Remove temp and backup files from a snapshot transaction.
runtime_snapshot_cleanup_transaction_files() {
	local snapshot_tmp="$1"
	local dst_tmp="$2"
	local src_tmp="$3"
	local direct_tmp="$4"
	local snapshot_backup="$5"
	local dst_backup="$6"
	local src_backup="$7"
	local direct_backup="$8"

	runtime_snapshot_cleanup_files \
		"$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp" \
		"$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup"
}

# Back up existing snapshot files before writing a new snapshot.
runtime_snapshot_backup_files() {
	local snapshot_file="$1"
	local dst_snapshot="$2"
	local src_snapshot="$3"
	local direct_snapshot="$4"
	local snapshot_backup="$5"
	local dst_backup="$6"
	local src_backup="$7"
	local direct_backup="$8"

	runtime_snapshot_backup_file "$snapshot_file" "$snapshot_backup" || return 1
	runtime_snapshot_backup_file "$dst_snapshot" "$dst_backup" || return 1
	runtime_snapshot_backup_file "$src_snapshot" "$src_backup" || return 1
	runtime_snapshot_backup_file "$direct_snapshot" "$direct_backup"
}

# Roll back snapshot file replacement transaction.
runtime_snapshot_restore_transaction() {
	local snapshot_file="$1"
	local dst_snapshot="$2"
	local src_snapshot="$3"
	local direct_snapshot="$4"
	local snapshot_backup="$5"
	local dst_backup="$6"
	local src_backup="$7"
	local direct_backup="$8"
	local snapshot_tmp="" dst_tmp="" src_tmp="" direct_tmp=""

	shift 8
	snapshot_tmp="$1"
	dst_tmp="$2"
	src_tmp="$3"
	direct_tmp="$4"

	runtime_snapshot_restore_backups \
		"$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" \
		"$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup"
	runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
}

# Commit temp snapshot files in a fixed order. Any failure restores previous
# files so snapshot never becomes a mixed old/new set.
runtime_snapshot_commit_files() {
	local snapshot_file="$1"
	local dst_snapshot="$2"
	local src_snapshot="$3"
	local direct_snapshot="$4"
	local snapshot_backup="$5"
	local dst_backup="$6"
	local src_backup="$7"
	local direct_backup="$8"
	local snapshot_tmp="" dst_tmp="" src_tmp="" direct_tmp=""

	shift 8
	snapshot_tmp="$1"
	dst_tmp="$2"
	src_tmp="$3"
	direct_tmp="$4"

	mv -f "$dst_tmp" "$dst_snapshot" || {
		runtime_snapshot_restore_transaction "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
	mv -f "$src_tmp" "$src_snapshot" || {
		runtime_snapshot_restore_transaction "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
	mv -f "$direct_tmp" "$direct_snapshot" || {
		runtime_snapshot_restore_transaction "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
	mv -f "$snapshot_tmp" "$snapshot_file" || {
		runtime_snapshot_restore_transaction "$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
}

# Save metadata and effective policy lists describing applied runtime state.
runtime_snapshot_save() {
	local snapshot_file dst_snapshot src_snapshot direct_snapshot
	local snapshot_tmp dst_tmp src_tmp direct_tmp
	local snapshot_backup dst_backup src_backup direct_backup
	local route_table_id="" route_rule_priority=""
	local dst_list_file="${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}"
	local src_list_file="${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}"
	local direct_list_file="${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}"
	local source_dst_list_file="${POLICY_SOURCE_DST_LIST_FILE:-$DST_LIST_FILE}"
	local source_src_list_file="${POLICY_SOURCE_SRC_LIST_FILE:-$SRC_LIST_FILE}"
	local source_direct_list_file="${POLICY_SOURCE_DIRECT_LIST_FILE:-$DIRECT_DST_LIST_FILE}"
	local dst_source_hash="" src_source_hash="" direct_source_hash=""

	require_command jq || return 1
	policy_route_state_read || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"
	direct_snapshot="$(runtime_snapshot_direct_file)"
	route_table_id="${ROUTE_TABLE_ID_EFFECTIVE:-}"
	route_rule_priority="${ROUTE_RULE_PRIORITY_EFFECTIVE:-}"
	dst_source_hash="$(policy_list_fingerprint "$source_dst_list_file")" || return 1
	src_source_hash="$(policy_list_fingerprint "$source_src_list_file")" || return 1
	direct_source_hash="$(policy_list_fingerprint "$source_direct_list_file")" || return 1

	ensure_dir "$(dirname "$snapshot_file")" || return 1
	snapshot_tmp="${snapshot_file}.tmp.$$"
	dst_tmp="${dst_snapshot}.tmp.$$"
	src_tmp="${src_snapshot}.tmp.$$"
	direct_tmp="${direct_snapshot}.tmp.$$"
	snapshot_backup="${snapshot_file}.bak.$$"
	dst_backup="${dst_snapshot}.bak.$$"
	src_backup="${src_snapshot}.bak.$$"
	direct_backup="${direct_snapshot}.bak.$$"

	runtime_snapshot_copy_file "$dst_list_file" "$dst_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
	runtime_snapshot_copy_file "$src_list_file" "$src_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}
	runtime_snapshot_copy_file "$direct_list_file" "$direct_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}

	jq -nc \
		--arg policy_mode "${POLICY_MODE:-direct-first}" \
		--arg dns_hijack "${DNS_HIJACK:-}" \
		--arg mihomo_dns_port "$MIHOMO_DNS_PORT" \
		--arg mihomo_dns_listen "$MIHOMO_DNS_LISTEN" \
		--arg mihomo_tproxy_port "$MIHOMO_TPROXY_PORT" \
		--arg mihomo_routing_mark "$MIHOMO_ROUTING_MARK" \
		--arg route_table_id_effective "$route_table_id" \
		--arg route_rule_priority_effective "$route_rule_priority" \
		--arg disable_quic "${DISABLE_QUIC:-}" \
		--arg dns_enhanced_mode "$DNS_ENHANCED_MODE" \
		--arg catch_fakeip "$CATCH_FAKEIP" \
		--arg fakeip_range "$FAKEIP_RANGE" \
		--arg source_interfaces "$SOURCE_INTERFACES" \
		--arg dst_source_hash "$dst_source_hash" \
		--arg src_source_hash "$src_source_hash" \
		--arg direct_source_hash "$direct_source_hash" \
		'{
			enabled: true,
			policy_mode: $policy_mode,
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
			always_proxy_dst_source_hash: $dst_source_hash,
			always_proxy_src_source_hash: $src_source_hash,
			direct_dst_source_hash: $direct_source_hash,
			source_network_interfaces: ($source_interfaces | split(" ") | map(select(length > 0)))
		}' >"$snapshot_tmp" || {
		runtime_snapshot_cleanup_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp"
		return 1
	}

	runtime_snapshot_backup_files \
		"$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" \
		"$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" || {
		runtime_snapshot_cleanup_transaction_files "$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp" "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup"
		return 1
	}
	runtime_snapshot_commit_files \
		"$snapshot_file" "$dst_snapshot" "$src_snapshot" "$direct_snapshot" \
		"$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup" \
		"$snapshot_tmp" "$dst_tmp" "$src_tmp" "$direct_tmp" || return 1

	runtime_snapshot_cleanup_files "$snapshot_backup" "$dst_backup" "$src_backup" "$direct_backup"
	if command -v policy_cache_save_current >/dev/null 2>&1; then
		policy_cache_save_current || warn "Failed to update persistent policy cache"
	fi
	log "Saved runtime snapshot"
	return 0
}

# Load snapshot data into runtime variables and point policy list paths at
# snapshot copies for rollback apply.
runtime_snapshot_load() {
	local snapshot_file
	local dst_snapshot src_snapshot direct_snapshot
	local snapshot_policy_mode="" snapshot_dns_hijack="" snapshot_mihomo_dns_port="" snapshot_mihomo_dns_listen=""
	local snapshot_mihomo_tproxy_port="" snapshot_mihomo_routing_mark="" snapshot_route_table_id=""
	local snapshot_route_rule_priority="" snapshot_disable_quic="" snapshot_dns_enhanced_mode=""
	local snapshot_catch_fakeip="" snapshot_fakeip_range="" snapshot_source_interfaces=""

	require_command jq || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"
	direct_snapshot="$(runtime_snapshot_direct_file)"

	[ -f "$snapshot_file" ] || return 1
	[ -f "$dst_snapshot" ] || return 1
	[ -f "$src_snapshot" ] || return 1
	[ -f "$direct_snapshot" ] || return 1

	eval "$(runtime_snapshot_vars "$snapshot_file")" || return 1
	POLICY_MODE="$snapshot_policy_mode"
	DNS_HIJACK="$snapshot_dns_hijack"
	MIHOMO_DNS_PORT="$snapshot_mihomo_dns_port"
	MIHOMO_DNS_LISTEN="$snapshot_mihomo_dns_listen"
	MIHOMO_TPROXY_PORT="$snapshot_mihomo_tproxy_port"
	MIHOMO_ROUTING_MARK="$snapshot_mihomo_routing_mark"
	MIHOMO_ROUTE_TABLE_ID="$snapshot_route_table_id"
	MIHOMO_ROUTE_RULE_PRIORITY="$snapshot_route_rule_priority"
	DISABLE_QUIC="$snapshot_disable_quic"
	DNS_ENHANCED_MODE="$snapshot_dns_enhanced_mode"
	CATCH_FAKEIP="$snapshot_catch_fakeip"
	FAKEIP_RANGE="$snapshot_fakeip_range"
	SOURCE_INTERFACES="$snapshot_source_interfaces"

	POLICY_DST_LIST_FILE="$dst_snapshot"
	POLICY_SRC_LIST_FILE="$src_snapshot"
	POLICY_DIRECT_DST_LIST_FILE="$direct_snapshot"
	return 0
}

# Emit shell assignments from snapshot JSON.
runtime_snapshot_vars_from_json() {
	jq -r '
		@sh "snapshot_policy_mode=\(.policy_mode // "direct-first") snapshot_dns_hijack=\(if (.dns_hijack // false) then 1 else 0 end) snapshot_mihomo_dns_port=\(.mihomo_dns_port // "") snapshot_mihomo_dns_listen=\(.mihomo_dns_listen // "") snapshot_mihomo_tproxy_port=\(.mihomo_tproxy_port // "") snapshot_mihomo_routing_mark=\(.mihomo_routing_mark // "") snapshot_route_table_id=\(.route_table_id_effective // "") snapshot_route_rule_priority=\(.route_rule_priority_effective // "") snapshot_disable_quic=\(if (.disable_quic // false) then 1 else 0 end) snapshot_dns_enhanced_mode=\(.dns_enhanced_mode // "") snapshot_catch_fakeip=\(if (.catch_fakeip // false) then 1 else 0 end) snapshot_fakeip_range=\(.fakeip_range // "") snapshot_source_interfaces=\((.source_network_interfaces // []) | join(" "))"
	'
}

# Read shell assignments from the selected snapshot file.
runtime_snapshot_vars() {
	local snapshot_file="${1:-}"

	require_command jq || return 1
	[ -n "$snapshot_file" ] || snapshot_file="$(runtime_snapshot_file)"
	[ -f "$snapshot_file" ] || return 1

	runtime_snapshot_vars_from_json <"$snapshot_file"
}

# Reapply the previous snapshot while preserving caller list path overrides.
runtime_snapshot_restore() {
	local prev_dst_list_file="" prev_src_list_file="" prev_direct_list_file=""
	local prev_dst_list_set=0 prev_src_list_set=0 prev_direct_list_set=0
	local rc=0

	[ "${POLICY_DST_LIST_FILE+x}" = x ] && {
		prev_dst_list_set=1
		prev_dst_list_file="$POLICY_DST_LIST_FILE"
	}
	[ "${POLICY_SRC_LIST_FILE+x}" = x ] && {
		prev_src_list_set=1
		prev_src_list_file="$POLICY_SRC_LIST_FILE"
	}
	[ "${POLICY_DIRECT_DST_LIST_FILE+x}" = x ] && {
		prev_direct_list_set=1
		prev_direct_list_file="$POLICY_DIRECT_DST_LIST_FILE"
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

	if [ "$prev_direct_list_set" -eq 1 ]; then
		POLICY_DIRECT_DST_LIST_FILE="$prev_direct_list_file"
	else
		unset POLICY_DIRECT_DST_LIST_FILE
	fi

	[ "$rc" -eq 0 ] || return "$rc"

	log "Restored previous runtime snapshot"
	return 0
}

# Full diagnostic snapshot JSON, including list entry counts.
runtime_snapshot_status_json() {
	local snapshot_file dst_snapshot src_snapshot direct_snapshot
	local dst_count=0 src_count=0 direct_count=0

	require_command jq || return 1
	runtime_snapshot_exists || return 1

	snapshot_file="$(runtime_snapshot_file)"
	dst_snapshot="$(runtime_snapshot_dst_file)"
	src_snapshot="$(runtime_snapshot_src_file)"
	direct_snapshot="$(runtime_snapshot_direct_file)"
	dst_count="$(count_valid_list_entries "$dst_snapshot")"
	src_count="$(count_valid_list_entries "$src_snapshot")"
	direct_count="$(count_valid_list_entries "$direct_snapshot")"

	jq -ec \
		--arg dst_count "$dst_count" \
		--arg src_count "$src_count" \
		--arg direct_count "$direct_count" \
		'if ((.enabled // false) != true) then
			error("runtime snapshot has disabled policy")
		elif ((((.policy_mode // "direct-first") == "direct-first") or ((.policy_mode // "direct-first") == "proxy-first")) | not) then
			error("runtime snapshot has invalid policy mode")
		elif ((.dns_enhanced_mode // "") != "fake-ip") then
			error("runtime snapshot is not fake-ip policy")
		elif ((.catch_fakeip // false) != true) then
			error("runtime snapshot does not catch fake-ip")
		elif ((.fakeip_range // "") == "") then
			error("runtime snapshot has empty fake-ip range")
		else {
			present: true,
			enabled: (.enabled // false),
			policy_mode: (.policy_mode // "direct-first"),
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
			always_proxy_dst_source_hash: (.always_proxy_dst_source_hash // ""),
			always_proxy_src_source_hash: (.always_proxy_src_source_hash // ""),
			direct_dst_source_hash: (.direct_dst_source_hash // ""),
			always_proxy_dst_count: (if (.policy_mode // "direct-first") == "direct-first" then ($dst_count | tonumber? // 0) else 0 end),
			always_proxy_src_count: (if (.policy_mode // "direct-first") == "direct-first" then ($src_count | tonumber? // 0) else 0 end),
			direct_dst_count: (if (.policy_mode // "direct-first") == "proxy-first" then ($direct_count | tonumber? // 0) else 0 end)
	} end' "$snapshot_file"
}

# Small readiness JSON used by service-ready fast path without counting lists.
runtime_snapshot_readiness_json() {
	local snapshot_file=""

	require_command jq || return 1
	runtime_snapshot_exists || return 1

	snapshot_file="$(runtime_snapshot_file)"
	jq -ec \
		'if ((.enabled // false) != true) then
			error("runtime snapshot has disabled policy")
		elif ((((.policy_mode // "direct-first") == "direct-first") or ((.policy_mode // "direct-first") == "proxy-first")) | not) then
			error("runtime snapshot has invalid policy mode")
		elif ((.dns_enhanced_mode // "") != "fake-ip") then
			error("runtime snapshot is not fake-ip policy")
		elif ((.catch_fakeip // false) != true) then
			error("runtime snapshot does not catch fake-ip")
		elif ((.fakeip_range // "") == "") then
			error("runtime snapshot has empty fake-ip range")
		else {
			mihomo_dns_port: (.mihomo_dns_port // ""),
			mihomo_dns_listen: (.mihomo_dns_listen // ""),
			mihomo_tproxy_port: (.mihomo_tproxy_port // "")
	} end' "$snapshot_file"
}

# True when current Mihomo-derived runtime fields match the active snapshot.
runtime_snapshot_mihomo_config_matches_current() {
	local snapshot_vars=""
	local snapshot_mihomo_dns_port="" snapshot_mihomo_dns_listen=""
	local snapshot_mihomo_tproxy_port="" snapshot_mihomo_routing_mark=""
	local snapshot_dns_enhanced_mode="" snapshot_catch_fakeip="" snapshot_fakeip_range=""

	snapshot_vars="$(runtime_snapshot_vars)" || return 1
	eval "$snapshot_vars" || return 1

	[ "$snapshot_mihomo_dns_port" = "$MIHOMO_DNS_PORT" ] || return 1
	[ "$snapshot_mihomo_dns_listen" = "$MIHOMO_DNS_LISTEN" ] || return 1
	[ "$snapshot_mihomo_tproxy_port" = "$MIHOMO_TPROXY_PORT" ] || return 1
	[ "$snapshot_mihomo_routing_mark" = "$MIHOMO_ROUTING_MARK" ] || return 1
	[ "$snapshot_dns_enhanced_mode" = "$DNS_ENHANCED_MODE" ] || return 1
	[ "$snapshot_catch_fakeip" = "$CATCH_FAKEIP" ] || return 1
	[ "$snapshot_fakeip_range" = "$FAKEIP_RANGE" ] || return 1
}

# True when current UCI policy fields match the active snapshot.
runtime_snapshot_policy_config_matches_current() {
	local snapshot_vars=""
	local snapshot_policy_mode="" snapshot_dns_hijack="" snapshot_disable_quic=""
	local snapshot_source_interfaces="" snapshot_route_table_id="" snapshot_route_rule_priority=""

	snapshot_vars="$(runtime_snapshot_vars)" || return 1
	eval "$snapshot_vars" || return 1

	[ "$snapshot_policy_mode" = "${POLICY_MODE:-direct-first}" ] || return 1
	[ "$snapshot_dns_hijack" = "$DNS_HIJACK" ] || return 1
	[ "$snapshot_disable_quic" = "$DISABLE_QUIC" ] || return 1
	[ "$snapshot_source_interfaces" = "$SOURCE_INTERFACES" ] || return 1
	if [ -n "$MIHOMO_ROUTE_TABLE_ID" ]; then
		[ "$snapshot_route_table_id" = "$MIHOMO_ROUTE_TABLE_ID" ] || return 1
	fi
	if [ -n "$MIHOMO_ROUTE_RULE_PRIORITY" ]; then
		[ "$snapshot_route_rule_priority" = "$MIHOMO_ROUTE_RULE_PRIORITY" ] || return 1
	fi
}

# True when route.state still matches snapshot metadata.
runtime_snapshot_route_state_matches_live() {
	local snapshot_vars=""
	local snapshot_route_table_id="" snapshot_route_rule_priority=""

	snapshot_vars="$(runtime_snapshot_vars)" || return 1
	eval "$snapshot_vars" || return 1

	[ "$snapshot_route_table_id" = "$ROUTE_TABLE_ID_EFFECTIVE" ] || return 1
	[ "$snapshot_route_rule_priority" = "$ROUTE_RULE_PRIORITY_EFFECTIVE" ] || return 1
}

# Compare currently resolved effective lists with snapshot copies.
runtime_resolved_policy_lists_match_snapshot() {
	case "${POLICY_MODE:-direct-first}" in
	direct-first)
		cmp -s "$(runtime_snapshot_dst_file)" "${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}" || return 1
		cmp -s "$(runtime_snapshot_src_file)" "${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}" || return 1
		;;
	proxy-first)
		cmp -s "$(runtime_snapshot_direct_file)" "${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}" || return 1
		;;
	*)
		return 1
		;;
	esac
}
