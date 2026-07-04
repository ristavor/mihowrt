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

policy_list_candidate_path_allowed() {
	local candidate="$1" base=""

	case "$candidate" in
	/tmp/mihowrt-policy-list.*) ;;
	*)
		err "policy list candidate must be stored under /tmp"
		return 1
		;;
	esac

	base="${candidate#/tmp/}"
	case "$base" in
	'' | */*)
		err "policy list candidate path must not contain subdirectories"
		return 1
		;;
	esac

	[ ! -L "$candidate" ] || {
		err "policy list candidate must not be a symlink"
		return 1
	}
	[ -f "$candidate" ] || {
		err "policy list candidate missing: $candidate"
		return 1
	}
}

policy_list_result_json() {
	local changed="$1"
	local reloaded="$2"

	require_command jq || return 1
	jq -nc \
		--arg changed "$changed" \
		--arg reloaded "$reloaded" \
		'{
			saved: true,
			changed: ($changed == "1"),
			reloaded: ($reloaded == "1")
		}'
}

policy_list_backup_path() {
	mktemp "${PKG_TMP_DIR:-/tmp/mihowrt}/policy-list-backup.XXXXXX"
}

policy_list_backup_file() {
	local target="$1"
	local backup="$2"

	if [ -f "$target" ]; then
		cp -f "$target" "$backup" || return 1
		printf '%s' 1
		return 0
	fi

	: >"$backup" || return 1
	printf '%s' 0
}

policy_list_restore_file() {
	local backup="$1"
	local present="$2"
	local target="$3"
	local tmp="${target}.rollback.$$"

	ensure_dir "$(dirname "$target")" || return 1
	if [ "$present" = "1" ]; then
		cp -f "$backup" "$tmp" || {
			rm -f "$tmp"
			return 1
		}
		mv -f "$tmp" "$target" || {
			rm -f "$tmp"
			return 1
		}
		return 0
	fi

	rm -f "$target"
}

policy_list_install_if_changed() {
	local source="$1"
	local target="$2"
	local tmp="${target}.tmp.$$"

	POLICY_LIST_FILE_CHANGED=0
	ensure_dir "$(dirname "$target")" || return 1

	if [ ! -s "$source" ]; then
		[ -e "$target" ] || return 0
		rm -f "$target" || return 1
		POLICY_LIST_FILE_CHANGED=1
		return 0
	fi

	if [ -f "$target" ] && cmp -s "$source" "$target" 2>/dev/null; then
		return 0
	fi

	cp -f "$source" "$tmp" || {
		rm -f "$tmp"
		return 1
	}
	mv -f "$tmp" "$target" || {
		rm -f "$tmp"
		return 1
	}
	POLICY_LIST_FILE_CHANGED=1
}

policy_lists_validate_candidates_for_reload() {
	local dst_candidate="$1"
	local src_candidate="$2"
	local direct_candidate="$3"
	local rc=0
	local prev_dst_set=0 prev_src_set=0 prev_direct_set=0
	local prev_dst="" prev_src="" prev_direct=""

	[ "${POLICY_DST_LIST_FILE+x}" = x ] && {
		prev_dst_set=1
		prev_dst="$POLICY_DST_LIST_FILE"
	}
	[ "${POLICY_SRC_LIST_FILE+x}" = x ] && {
		prev_src_set=1
		prev_src="$POLICY_SRC_LIST_FILE"
	}
	[ "${POLICY_DIRECT_DST_LIST_FILE+x}" = x ] && {
		prev_direct_set=1
		prev_direct="$POLICY_DIRECT_DST_LIST_FILE"
	}

	load_runtime_config || return 1
	POLICY_DST_LIST_FILE="$dst_candidate"
	POLICY_SRC_LIST_FILE="$src_candidate"
	POLICY_DIRECT_DST_LIST_FILE="$direct_candidate"

	if policy_resolve_runtime_lists_without_cache; then
		rc=0
	else
		rc=$?
	fi

	[ -z "${POLICY_EFFECTIVE_LIST_FILES:-}" ] || policy_clear_runtime_list_overrides

	if [ "$prev_dst_set" -eq 1 ]; then
		POLICY_DST_LIST_FILE="$prev_dst"
	else
		unset POLICY_DST_LIST_FILE
	fi
	if [ "$prev_src_set" -eq 1 ]; then
		POLICY_SRC_LIST_FILE="$prev_src"
	else
		unset POLICY_SRC_LIST_FILE
	fi
	if [ "$prev_direct_set" -eq 1 ]; then
		POLICY_DIRECT_DST_LIST_FILE="$prev_direct"
	else
		unset POLICY_DIRECT_DST_LIST_FILE
	fi

	return "$rc"
}

apply_policy_lists_runtime() {
	local reload_requested="$1"
	local dst_candidate="$2"
	local src_candidate="$3"
	local direct_candidate="$4"
	local reload_needed=0 changed=0 reloaded=0
	local dst_backup="" src_backup="" direct_backup=""
	local dst_present=0 src_present=0 direct_present=0
	local rc=0

	case "$reload_requested" in
	1 | true | yes) reload_requested=1 ;;
	*) reload_requested=0 ;;
	esac

	policy_list_candidate_path_allowed "$dst_candidate" || return 1
	policy_list_candidate_path_allowed "$src_candidate" || return 1
	policy_list_candidate_path_allowed "$direct_candidate" || return 1
	ensure_dir "${PKG_TMP_DIR:-/tmp/mihowrt}" || return 1

	if [ "$reload_requested" -eq 1 ] && service_running_state; then
		reload_needed=1
		policy_lists_validate_candidates_for_reload "$dst_candidate" "$src_candidate" "$direct_candidate" || {
			rm -f "$dst_candidate" "$src_candidate" "$direct_candidate"
			return 1
		}
	fi

	dst_backup="$(policy_list_backup_path)" || return 1
	src_backup="$(policy_list_backup_path)" || {
		rm -f "$dst_backup"
		return 1
	}
	direct_backup="$(policy_list_backup_path)" || {
		rm -f "$dst_backup" "$src_backup"
		return 1
	}

	if ! dst_present="$(policy_list_backup_file "$DST_LIST_FILE" "$dst_backup")" ||
		! src_present="$(policy_list_backup_file "$SRC_LIST_FILE" "$src_backup")" ||
		! direct_present="$(policy_list_backup_file "$DIRECT_DST_LIST_FILE" "$direct_backup")"; then
		rm -f "$dst_backup" "$src_backup" "$direct_backup" "$dst_candidate" "$src_candidate" "$direct_candidate"
		return 1
	fi

	if policy_list_install_if_changed "$dst_candidate" "$DST_LIST_FILE"; then
		[ "$POLICY_LIST_FILE_CHANGED" -eq 1 ] && changed=1
	else
		rc=1
	fi
	if [ "$rc" -eq 0 ]; then
		if policy_list_install_if_changed "$src_candidate" "$SRC_LIST_FILE"; then
			[ "$POLICY_LIST_FILE_CHANGED" -eq 1 ] && changed=1
		else
			rc=1
		fi
	fi
	if [ "$rc" -eq 0 ]; then
		if policy_list_install_if_changed "$direct_candidate" "$DIRECT_DST_LIST_FILE"; then
			[ "$POLICY_LIST_FILE_CHANGED" -eq 1 ] && changed=1
		else
			rc=1
		fi
	fi
	if [ "$rc" -ne 0 ]; then
		policy_list_restore_file "$direct_backup" "$direct_present" "$DIRECT_DST_LIST_FILE" || true
		policy_list_restore_file "$src_backup" "$src_present" "$SRC_LIST_FILE" || true
		policy_list_restore_file "$dst_backup" "$dst_present" "$DST_LIST_FILE" || true
		rm -f "$dst_backup" "$src_backup" "$direct_backup" "$dst_candidate" "$src_candidate" "$direct_candidate"
		return 1
	fi

	if [ "$changed" -eq 1 ] && [ "$reload_needed" -eq 1 ]; then
		if reload_runtime_state; then
			reloaded=1
		else
			err "Policy reload failed after list save; restoring previous policy list files"
			policy_list_restore_file "$direct_backup" "$direct_present" "$DIRECT_DST_LIST_FILE" || true
			policy_list_restore_file "$src_backup" "$src_present" "$SRC_LIST_FILE" || true
			policy_list_restore_file "$dst_backup" "$dst_present" "$DST_LIST_FILE" || true
			rm -f "$dst_backup" "$src_backup" "$direct_backup" "$dst_candidate" "$src_candidate" "$direct_candidate"
			return 1
		fi
	fi

	rm -f "$dst_backup" "$src_backup" "$direct_backup" "$dst_candidate" "$src_candidate" "$direct_candidate"
	policy_list_result_json "$changed" "$reloaded"
}

policy_resolve_runtime_lists_without_cache() {
	local previous_cache_fallback="" previous_cache_fallback_set=0 rc=0

	if [ "${POLICY_ALLOW_CACHE_FALLBACK+x}" = x ]; then
		previous_cache_fallback_set=1
		previous_cache_fallback="$POLICY_ALLOW_CACHE_FALLBACK"
	fi

	POLICY_ALLOW_CACHE_FALLBACK=0
	if policy_resolve_runtime_lists; then
		rc=0
	else
		rc=$?
	fi

	if [ "$previous_cache_fallback_set" -eq 1 ]; then
		POLICY_ALLOW_CACHE_FALLBACK="$previous_cache_fallback"
	else
		unset POLICY_ALLOW_CACHE_FALLBACK
	fi

	return "$rc"
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

	policy_resolve_runtime_lists_without_cache || {
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
