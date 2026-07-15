#!/bin/ash

migrate_legacy_uci_settings() {
	local pkg_config="${PKG_CONFIG:-mihowrt}"
	local policy_mode="" changed=0 legacy_enabled_present=0 option=""

	have_command uci || return 0

	if uci -q get "$pkg_config.settings.enabled" >/dev/null 2>&1; then
		legacy_enabled_present=1
	fi

	policy_mode="$(uci -q get "$pkg_config.settings.policy_mode" 2>/dev/null || true)"
	case "$policy_mode" in
	direct-first | proxy-first)
		;;
	*)
		uci -q set "$pkg_config.settings=settings" || {
			err "Failed to prepare MihoWRT UCI settings section"
			return 1
		}
		uci -q set "$pkg_config.settings.policy_mode=direct-first" || {
			err "Failed to migrate MihoWRT policy_mode to direct-first"
			return 1
		}
		changed=1
		;;
	esac

	if [ "$legacy_enabled_present" = "1" ]; then
		uci -q delete "$pkg_config.settings.enabled" || {
			err "Failed to remove legacy MihoWRT enabled option"
			return 1
		}
		changed=1
	fi

	for option in route_table_id route_rule_priority; do
		if uci -q get "$pkg_config.settings.$option" >/dev/null 2>&1; then
			uci -q delete "$pkg_config.settings.$option" || {
				err "Failed to remove obsolete MihoWRT $option option"
				return 1
			}
			changed=1
		fi
	done

	[ "$changed" = "1" ] || return 0
	uci -q commit "$pkg_config" || {
		err "Failed to commit migrated MihoWRT UCI settings"
		return 1
	}
	log "Migrated legacy MihoWRT UCI settings"
}

migrate_policy_remote_interval_file() {
	local file="$1" interval="$2" tmp_file="" line="" trimmed="" changed=0

	[ -f "$file" ] || return 0
	tmp_file="${file}.intervals.tmp.$$"
	: >"$tmp_file" || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		trimmed="$(trim "$line")"
		if is_policy_remote_list_url "$trimmed"; then
			case "$trimmed" in
			*'|'*) printf '%s\n' "$line" >>"$tmp_file" || return 1 ;;
			*)
				printf '%s | %s\n' "$trimmed" "$interval" >>"$tmp_file" || return 1
				changed=1
				;;
			esac
		else
			printf '%s\n' "$line" >>"$tmp_file" || return 1
		fi
	done <"$file"

	if [ "$changed" -eq 1 ]; then
		mv -f "$tmp_file" "$file" || return 1
	else
		rm -f "$tmp_file"
	fi
}

migrate_policy_remote_intervals() {
	local pkg_config="${PKG_CONFIG:-mihowrt}" interval="0" changed=0

	if have_command uci; then
		interval="$(uci -q get "$pkg_config.settings.policy_remote_update_interval" 2>/dev/null || true)"
	fi
	policy_remote_update_interval_valid "$interval" || interval=0
	interval="$(normalize_uint "$interval")"

	migrate_policy_remote_interval_file "$DST_LIST_FILE" "$interval" || return 1
	migrate_policy_remote_interval_file "$SRC_LIST_FILE" "$interval" || return 1
	migrate_policy_remote_interval_file "$DIRECT_DST_LIST_FILE" "$interval" || return 1

	if have_command uci && uci -q get "$pkg_config.settings.policy_remote_update_interval" >/dev/null 2>&1; then
		uci -q delete "$pkg_config.settings.policy_remote_update_interval" || return 1
		changed=1
	fi
	[ "$changed" -eq 0 ] || uci -q commit "$pkg_config"
}

migrate_all() {
	migrate_legacy_uci_settings || return 1
	migrate_policy_list_files || return 1
	migrate_policy_remote_intervals || return 1
}
