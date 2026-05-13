#!/bin/ash

# Detect any live managed state that would need cleanup/recovery.
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

# Validate config and apply full runtime state from clean start path.
prepare_runtime_state() {
	load_runtime_config || return 1
	validate_runtime_config || return 1
	apply_runtime_state
}

# Apply route -> nft -> DNS in dependency order. Later failures roll back earlier
# mutations so traffic is not left half-routed.
apply_runtime_state_internal() {
	ensure_dir "$PKG_TMP_DIR"

	policy_route_setup || return 1
	if ! nft_apply_policy; then
		policy_route_cleanup
		return 1
	fi

	if ! dns_setup; then
		rollback_applied_runtime_state
		return 1
	fi

	log "Prepared ${POLICY_MODE:-direct-first} policy state"
	return 0
}

# Best-effort rollback for partial runtime apply.
rollback_applied_runtime_state() {
	dns_restore || true
	nft_remove_policy || true
	policy_route_cleanup || true
}

# Remove temp effective policy lists only when this transaction created them.
clear_resolved_runtime_lists() {
	[ "${1:-0}" -eq 0 ] || policy_clear_runtime_list_overrides
}

# Reapply nft only, used by remote list update when route/DNS/config are stable.
apply_runtime_nft_policy_only() {
	ensure_dir "$PKG_TMP_DIR"
	nft_apply_policy || return 1
	log "Updated ${POLICY_MODE:-direct-first} nft policy"
	return 0
}

# Full apply transaction: resolve remote lists, apply runtime state, then save
# snapshot that represents exactly what was applied.
apply_runtime_state_resolved() {
	if ! apply_runtime_state_internal; then
		return 1
	fi

	runtime_snapshot_save || {
		err "Failed to persist runtime snapshot"
		rollback_applied_runtime_state
		return 1
	}

	return 0
}

apply_runtime_state() {
	local lists_resolved=0

	if command -v policy_resolve_runtime_lists >/dev/null 2>&1; then
		policy_resolve_runtime_lists || return 2
		lists_resolved=1
	fi

	if ! apply_runtime_state_resolved; then
		clear_resolved_runtime_lists "$lists_resolved"
		return 1
	fi

	clear_resolved_runtime_lists "$lists_resolved"
	return 0
}

# Cleanup runtime state. Unknown nft errors are treated as live state so cleanup
# errs on the side of trying to remove stale state.
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
			command -v mihomo_api_live_state_clear >/dev/null 2>&1 && mihomo_api_live_state_clear
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
		command -v mihomo_api_live_state_clear >/dev/null 2>&1 && mihomo_api_live_state_clear
		log "Cleaned up policy state"
		return 0
	fi

	err "Policy cleanup incomplete"
	return 1
}

# Boot/service recovery entrypoint.
recover_runtime_state() {
	runtime_live_state_present || return 0
	log "Recovering runtime state after unclean shutdown"
	cleanup_runtime_state
}

runtime_changed_policy_components() {
	local components=""

	case "${POLICY_MODE:-direct-first}" in
	direct-first)
		cmp -s "$(runtime_snapshot_dst_file)" "${POLICY_DST_LIST_FILE:-$DST_LIST_FILE}" || components="${components}${components:+ }proxy_dst"
		cmp -s "$(runtime_snapshot_src_file)" "${POLICY_SRC_LIST_FILE:-$SRC_LIST_FILE}" || components="${components}${components:+ }proxy_src"
		;;
	proxy-first)
		cmp -s "$(runtime_snapshot_direct_file)" "${POLICY_DIRECT_DST_LIST_FILE:-$DIRECT_DST_LIST_FILE}" || components="${components}${components:+ }direct_dst"
		;;
	*)
		return 1
		;;
	esac

	printf '%s\n' "$components"
}

runtime_fast_update_resolved_policy_lists() {
	local components="" component=""

	FAST_NFT_UPDATE_COMPONENTS=""
	components="$(runtime_changed_policy_components)" || return 1
	[ -n "$components" ] || return 0

	command -v nft_table_exists >/dev/null 2>&1 || return 2
	command -v nft_policy_component_fast_update_supported >/dev/null 2>&1 || return 2
	command -v nft_update_policy_components_fast >/dev/null 2>&1 || return 2

	nft_table_exists || return 2
	for component in $components; do
		nft_policy_component_fast_update_supported "$component" || return 2
	done

	nft_update_policy_components_fast "$components" || return 1
	FAST_NFT_UPDATE_COMPONENTS="$components"
	return 0
}

runtime_save_snapshot_after_fast_update() {
	if ! runtime_snapshot_save; then
		err "Failed to persist runtime snapshot"
		runtime_snapshot_restore || err "Failed to restore previous runtime state"
		return 1
	fi

	return 0
}

# Policy reload with snapshot safety. It refuses in-place reload when the old
# live state cannot be identified well enough for rollback.
reload_runtime_state() {
	local old_route_table_id="" old_route_rule_priority=""
	local new_route_table_id="" new_route_rule_priority=""
	local had_snapshot=0 snapshot_files_present=0 live_runtime_present=0
	local apply_rc=0 lists_resolved=0 fast_rc=0

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

	if [ "${MIHOWRT_ALLOW_MIHOMO_CONFIG_RELOAD:-0}" != "1" ] && ! runtime_snapshot_mihomo_config_matches_current; then
		err "Mihomo config changed since runtime snapshot; restart MihoWRT service to apply DNS/TPROXY/fake-ip settings"
		return 1
	fi

	if runtime_snapshot_policy_config_matches_current && runtime_snapshot_route_state_matches_live &&
		command -v policy_resolve_runtime_lists >/dev/null 2>&1; then
		policy_resolve_runtime_lists || {
			err "Failed to prepare updated policy lists"
			return 1
		}
		lists_resolved=1
		runtime_fast_update_resolved_policy_lists
		fast_rc=$?
		case "$fast_rc" in
		0)
			if ! runtime_save_snapshot_after_fast_update; then
				policy_clear_runtime_list_overrides
				return 1
			fi
			policy_clear_runtime_list_overrides
			log "Reloaded ${POLICY_MODE:-direct-first} policy state"
			return 0
			;;
		2)
			:
			;;
		*)
			err "Failed to update nft policy components; restoring previous runtime state"
			policy_clear_runtime_list_overrides
			runtime_snapshot_restore || {
				err "Failed to restore previous runtime state"
				return 1
			}
			return 1
			;;
		esac
	fi

	if [ "$lists_resolved" -eq 1 ]; then
		apply_runtime_state_resolved
	else
		apply_runtime_state
	fi
	apply_rc=$?
	clear_resolved_runtime_lists "$lists_resolved"
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

# Refresh remote policy lists while service is running. nft is skipped when
# effective list content matches the snapshot.
update_runtime_policy_lists() {
	local apply_rc=0 snapshot_rc=0 lists_changed=1 fast_rc=0

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

	runtime_fast_update_resolved_policy_lists
	fast_rc=$?
	case "$fast_rc" in
	0)
		if ! runtime_snapshot_save; then
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
		;;
	2)
		:
		;;
	*)
		policy_clear_runtime_list_overrides
		err "Failed to apply updated policy lists; restoring previous runtime state"
		runtime_snapshot_restore || {
			err "Failed to restore previous runtime state"
			return 1
		}
		return 1
		;;
	esac

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
