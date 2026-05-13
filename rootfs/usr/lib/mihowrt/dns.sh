#!/bin/ash

# Runtime dnsmasq backup lives in tmpfs and is removed after normal cleanup.
dns_runtime_backup_file() {
	printf '%s\n' "${DNS_RUNTIME_BACKUP_FILE:-${PKG_STATE_DIR:-/var/run/mihowrt}/dns.backup}"
}

dns_runtime_backup_exists() {
	[ -f "$(dns_runtime_backup_file)" ]
}

dns_persist_backup_exists() {
	[ -f "$DNS_BACKUP_FILE" ]
}

dns_persist_backup_valid() {
	dns_backup_file_valid "$DNS_BACKUP_FILE"
}

# Reject control characters in backup values before using them in UCI restore.
dns_backup_text_has_controls() {
	case "$1" in
	*[[:cntrl:]]*)
		return 0
		;;
	esac

	return 1
}

dns_backup_server_atom_valid() {
	is_dns_listen_host "$1"
}

dns_backup_server_selector_valid() {
	case "$1" in
	'' | *[!#A-Za-z0-9._*:/-]*)
		return 1
		;;
	esac

	return 0
}

# Validate one dnsmasq server target value from backup data.
dns_backup_server_target_valid() {
	local value="$1"
	local host="" port=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls "$value" && return 1
	string_has_space "$value" && return 1

	case "$value" in
	*#*)
		host="${value%#*}"
		port="${value##*#}"
		[ -n "$host" ] || return 1
		case "$host" in
		*'#'* | */*)
			return 1
			;;
		esac
		dns_backup_server_atom_valid "$host" || return 1
		is_valid_port "$port" || return 1
		;;
	*)
		case "$value" in
		*/*)
			return 1
			;;
		esac
		dns_backup_server_atom_valid "$value" || return 1
		;;
	esac

	return 0
}

# Validate complete dnsmasq server list item, including domain selectors.
dns_backup_server_value_valid() {
	local value="$1"
	local rest="" prefix="" target=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls "$value" && return 1
	string_has_space "$value" && return 1

	case "$value" in
	/*)
		rest="${value#/}"
		case "$rest" in
		*/*) ;;
		*)
			return 1
			;;
		esac
		prefix="${rest%/*}"
		target="${rest##*/}"
		dns_backup_server_selector_valid "$prefix" || return 1
		[ -z "$target" ] && return 0
		[ "$target" = "#" ] && return 0
		dns_backup_server_target_valid "$target"
		;;
	*)
		dns_backup_server_target_valid "$value"
		;;
	esac
}

# Only absolute resolvfile paths or empty value are restorable.
dns_backup_resolvfile_value_valid() {
	local value="$1"

	[ -n "$value" ] || return 0
	dns_backup_text_has_controls "$value" && return 1

	case "$value" in
	/*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

# Validate fields parsed from DNS backup before any UCI restore.
dns_backup_parsed_state_valid() {
	if [ -n "$DNS_BACKUP_EXPECTED_CACHESIZE" ] && ! is_uint "$DNS_BACKUP_EXPECTED_CACHESIZE"; then
		return 1
	fi

	case "$DNS_BACKUP_EXPECTED_NORESOLV" in
	'' | 0 | 1)
		:
		;;
	*)
		return 1
		;;
	esac

	if [ -n "$DNS_BACKUP_MIHOMO_TARGET" ] && ! is_dns_listen "$DNS_BACKUP_MIHOMO_TARGET"; then
		return 1
	fi

	dns_backup_resolvfile_value_valid "$DNS_BACKUP_EXPECTED_RESOLVFILE" || return 1

	return 0
}

# Parse DNS backup into DNS_BACKUP_EXPECTED_* variables. The derived target
# noresolv/resolvfile values handle OpenWrt default resolvfile fallback.
dns_backup_parse_expected_state() {
	local backup_path="$1"
	local line server tab="" server_sep=""
	local seen_backup=0 seen_cachesize=0 seen_noresolv=0 seen_resolvfile=0

	[ -f "$backup_path" ] || return 1

	DNS_BACKUP_EXPECTED_CACHESIZE=''
	DNS_BACKUP_EXPECTED_NORESOLV=''
	DNS_BACKUP_EXPECTED_RESOLVFILE=''
	DNS_BACKUP_EXPECTED_TARGET_NORESOLV=''
	DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE=''
	DNS_BACKUP_EXPECTED_SERVERS=''
	DNS_BACKUP_EXPECTED_HAS_SERVERS=0
	DNS_BACKUP_MIHOMO_TARGET=''
	tab="$(printf '\t')"

	while IFS= read -r line; do
		case "$line" in
		DNSMASQ_BACKUP=1)
			seen_backup=1
			;;
		MIHOMO_DNS_TARGET=*)
			DNS_BACKUP_MIHOMO_TARGET="${line#MIHOMO_DNS_TARGET=}"
			;;
		ORIG_CACHESIZE=*)
			seen_cachesize=1
			DNS_BACKUP_EXPECTED_CACHESIZE="${line#ORIG_CACHESIZE=}"
			;;
		ORIG_NORESOLV=*)
			seen_noresolv=1
			DNS_BACKUP_EXPECTED_NORESOLV="${line#ORIG_NORESOLV=}"
			;;
		ORIG_RESOLVFILE=*)
			seen_resolvfile=1
			DNS_BACKUP_EXPECTED_RESOLVFILE="${line#ORIG_RESOLVFILE=}"
			;;
		ORIG_SERVER=*)
			server="${line#ORIG_SERVER=}"
			if [ -n "$server" ]; then
				dns_backup_server_value_valid "$server" || return 1
				DNS_BACKUP_EXPECTED_SERVERS="${DNS_BACKUP_EXPECTED_SERVERS}${server_sep}${server}"
				server_sep="$tab"
				DNS_BACKUP_EXPECTED_HAS_SERVERS=1
			fi
			;;
		esac
	done <"$backup_path"

	[ "$seen_backup" -eq 1 ] || return 1
	[ "$seen_cachesize" -eq 1 ] || return 1
	[ "$seen_noresolv" -eq 1 ] || return 1
	[ "$seen_resolvfile" -eq 1 ] || return 1
	dns_backup_parsed_state_valid || return 1

	DNS_BACKUP_EXPECTED_TARGET_NORESOLV="$DNS_BACKUP_EXPECTED_NORESOLV"
	DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE="$DNS_BACKUP_EXPECTED_RESOLVFILE"
	if [ -z "$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" ] &&
		[ "$DNS_BACKUP_EXPECTED_HAS_SERVERS" -eq 0 ] &&
		[ -f "${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" ]; then
		DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}"
		[ "$DNS_BACKUP_EXPECTED_NORESOLV" = "1" ] || DNS_BACKUP_EXPECTED_TARGET_NORESOLV='0'
	fi
}

# Syntax and semantic validation for a backup file.
dns_backup_file_valid() {
	dns_backup_parse_expected_state "$1" >/dev/null 2>&1
}

# True when runtime backup exists or persistent backup is needed for recovery.
dns_backup_exists() {
	dns_runtime_backup_exists && return 0
	dns_persist_backup_recovery_needed
}

dns_backup_valid() {
	local runtime_backup=""

	runtime_backup="$(dns_runtime_backup_file)"
	dns_backup_file_valid "$runtime_backup" && return 0
	dns_persist_backup_recovery_needed
}

dns_restart_service() {
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
}

dns_cleanup_backup_files() {
	rm -f "$(dns_runtime_backup_file)"
}

# Load expected restore state from a backup file.
dns_backup_read_expected_state() {
	dns_backup_parse_expected_state "$1"
}

# Detect dnsmasq state that still points to Mihomo DNS, so cleanup can recover
# even if runtime tmpfs backup disappeared after power loss.
dns_current_state_looks_hijacked() {
	local expected_target="${1:-}" current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""
	local current_host="" current_port="" tab=""

	current_cachesize="$(dnsmasq_option_get cachesize)"
	current_noresolv="$(dnsmasq_option_get noresolv)"
	current_resolvfile="$(dnsmasq_option_get resolvfile)"
	current_servers="$(dns_current_servers_flat)"
	tab="$(printf '\t')"

	[ "$current_cachesize" = "0" ] || return 1
	[ "$current_noresolv" = "1" ] || return 1
	[ -z "$current_resolvfile" ] || return 1
	[ -n "$current_servers" ] || return 1

	case "$current_servers" in
	*"${tab}"*)
		return 1
		;;
	*"#"*)
		current_host="${current_servers%#*}"
		current_port="${current_servers##*#}"
		[ -n "$current_host" ] || return 1
		is_valid_port "$current_port" || return 1
		;;
	*)
		return 1
		;;
	esac

	if [ -n "$expected_target" ]; then
		[ "$current_servers" = "$expected_target" ] || return 1
	else
		case "$current_host" in
		127.0.0.1 | ::1 | localhost)
			:
			;;
		*)
			return 1
			;;
		esac
	fi

	return 0
}

# Resolve current Mihomo DNS target from runtime vars, snapshot, or config.
dns_runtime_mihomo_target() {
	local config_json="" mihomo_dns_listen="" snapshot_json=""

	if [ -n "${MIHOMO_DNS_LISTEN:-}" ]; then
		normalize_dns_server_target "$MIHOMO_DNS_LISTEN"
		return $?
	fi

	if command -v runtime_snapshot_status_json >/dev/null 2>&1; then
		snapshot_json="$(runtime_snapshot_status_json 2>/dev/null || true)"
		if [ -n "$snapshot_json" ]; then
			mihomo_dns_listen="$(printf '%s\n' "$snapshot_json" | jq -r '.mihomo_dns_listen // ""' 2>/dev/null || true)"
			if [ -n "$mihomo_dns_listen" ]; then
				normalize_dns_server_target "$mihomo_dns_listen"
				return $?
			fi
		fi
	fi

	config_json="$(read_config_json 2>/dev/null || true)"
	[ -n "$config_json" ] || return 1

	mihomo_dns_listen="$(printf '%s\n' "$config_json" | jq -r '
		if ((.errors // []) | length) > 0 then empty else (.mihomo_dns_listen // "") end
	' 2>/dev/null || true)"
	[ -n "$mihomo_dns_listen" ] || return 1

	normalize_dns_server_target "$mihomo_dns_listen"
}

# Persistent backup is only actionable when current dnsmasq still appears
# hijacked and expected state has not already been restored.
dns_persist_backup_recovery_needed() {
	local expected_target=""

	dns_persist_backup_exists || return 1
	dns_backup_read_expected_state "$DNS_BACKUP_FILE" || return 1
	expected_target="$DNS_BACKUP_MIHOMO_TARGET"
	[ -n "$expected_target" ] || expected_target="$(dns_runtime_mihomo_target 2>/dev/null || true)"
	dns_current_state_looks_hijacked "$expected_target" || return 1
	dns_expected_state_matches_current && return 1
	return 0
}

# Compare parsed expected state with current dnsmasq UCI state.
dns_expected_state_matches_current() {
	dnsmasq_state_matches \
		"$DNS_BACKUP_EXPECTED_CACHESIZE" \
		"$DNS_BACKUP_EXPECTED_TARGET_NORESOLV" \
		"$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" \
		"$DNS_BACKUP_EXPECTED_SERVERS"
}

# Pick runtime backup first, then persistent backup if recovery is still needed.
dns_backup_source_file() {
	local runtime_backup=""

	runtime_backup="$(dns_runtime_backup_file)"
	if dns_backup_file_valid "$runtime_backup"; then
		printf '%s\n' "$runtime_backup"
		return 0
	fi

	if dns_persist_backup_recovery_needed; then
		printf '%s\n' "$DNS_BACKUP_FILE"
		return 0
	fi

	return 1
}

# Save current dnsmasq state to runtime and persistent backups. Persistent file
# changes only when content differs to avoid needless NAND writes.
dns_backup_state() {
	local backup_tmp persist_tmp runtime_backup="" server mihomo_dns_target=""

	runtime_backup="$(dns_runtime_backup_file)"
	ensure_dir "$(dirname "$runtime_backup")"
	ensure_dir "$PKG_PERSIST_DIR"
	backup_tmp="${runtime_backup}.tmp.$$"
	persist_tmp="${DNS_BACKUP_FILE}.tmp.$$"
	if [ -n "${MIHOMO_DNS_LISTEN:-}" ]; then
		mihomo_dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN" 2>/dev/null || true)"
	fi

	: >"$backup_tmp" || return 1

	{
		printf 'DNSMASQ_BACKUP=1\n'
		printf 'MIHOMO_DNS_TARGET=%s\n' "$mihomo_dns_target"
		printf 'ORIG_CACHESIZE=%s\n' "$(dnsmasq_option_get cachesize)"
		printf 'ORIG_NORESOLV=%s\n' "$(dnsmasq_option_get noresolv)"
		printf 'ORIG_RESOLVFILE=%s\n' "$(dnsmasq_option_get resolvfile)"
		uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | while IFS= read -r server; do
			printf 'ORIG_SERVER=%s\n' "$server"
		done
	} >>"$backup_tmp" || {
		rm -f "$backup_tmp" "$persist_tmp"
		return 1
	}

	if [ ! -f "$DNS_BACKUP_FILE" ] || ! cmp -s "$backup_tmp" "$DNS_BACKUP_FILE" 2>/dev/null; then
		cp -f "$backup_tmp" "$persist_tmp" || {
			rm -f "$backup_tmp" "$persist_tmp"
			return 1
		}
		mv -f "$persist_tmp" "$DNS_BACKUP_FILE" || {
			rm -f "$backup_tmp" "$persist_tmp"
			return 1
		}
	fi

	if [ -f "$runtime_backup" ] && cmp -s "$backup_tmp" "$runtime_backup" 2>/dev/null; then
		rm -f "$backup_tmp"
		return 0
	fi

	mv -f "$backup_tmp" "$runtime_backup" || {
		rm -f "$backup_tmp" "$persist_tmp"
		return 1
	}

	return 0
}

# Drop staged UCI changes after a failed DNS apply/restore.
dns_revert_staged_changes() {
	uci revert dhcp >/dev/null 2>&1 || true
}

dns_delete_option_if_present() {
	local option="$1"

	uci -q get "$option" >/dev/null 2>&1 || return 0
	uci -q delete "$option" 2>/dev/null
}

dns_stage_option_value() {
	local option="$1"
	local value="$2"

	if [ -n "$value" ]; then
		uci set "$option=$value" 2>/dev/null
	else
		dns_delete_option_if_present "$option"
	fi
}

dns_stage_clear_dnsmasq_targets() {
	dns_delete_option_if_present dhcp.@dnsmasq[0].server || return 1
	dns_delete_option_if_present dhcp.@dnsmasq[0].resolvfile
}

# Rebuild dnsmasq server list from the tab-delimited backup representation.
dns_stage_dnsmasq_servers_flat() {
	local servers="$1"
	local old_ifs="" tab="" server=""

	[ -n "$servers" ] || return 0

	tab="$(printf '\t')"
	old_ifs="$IFS"
	IFS="$tab"
	for server in $servers; do
		[ -n "$server" ] || continue
		uci add_list dhcp.@dnsmasq[0].server="$server" || {
			IFS="$old_ifs"
			return 1
		}
	done
	IFS="$old_ifs"
}

# Stage dnsmasq state that sends all router DNS to Mihomo.
dns_stage_hijack_state() {
	local dns_target="$1"

	dns_stage_clear_dnsmasq_targets || return 1
	uci add_list dhcp.@dnsmasq[0].server="$dns_target" || return 1
	uci set dhcp.@dnsmasq[0].cachesize='0' || return 1
	uci set dhcp.@dnsmasq[0].noresolv='1' || return 1
}

# Stage safe OpenWrt-ish defaults when no trustworthy backup can be used.
dns_stage_fallback_state() {
	local resolvfile="$1"

	dns_stage_clear_dnsmasq_targets || return 1
	dns_stage_option_value dhcp.@dnsmasq[0].cachesize "" || return 1
	uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || return 1

	[ -z "$resolvfile" ] || uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile" 2>/dev/null
}

# Stage exact state parsed from backup.
dns_stage_expected_restore_state() {
	dns_stage_clear_dnsmasq_targets || return 1
	dns_stage_dnsmasq_servers_flat "$DNS_BACKUP_EXPECTED_SERVERS" || return 1
	dns_stage_option_value dhcp.@dnsmasq[0].cachesize "$DNS_BACKUP_EXPECTED_CACHESIZE" || return 1
	dns_stage_option_value dhcp.@dnsmasq[0].noresolv "$DNS_BACKUP_EXPECTED_TARGET_NORESOLV" || return 1
	[ -z "$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" ] ||
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" 2>/dev/null
}

# Commit DHCP UCI and restart dnsmasq, reverting uncommitted changes on commit
# failure.
dns_commit_dhcp_and_restart() {
	local restart_error="$1"

	uci commit dhcp || {
		dns_revert_staged_changes
		return 1
	}

	if ! dns_restart_service; then
		err "$restart_error"
		return 1
	fi
}

# Fallback restore for crash recovery when backup is missing/invalid but dnsmasq
# still points at Mihomo.
dns_restore_fallback() {
	local resolvfile=""

	warn "dnsmasq backup state unavailable, applying fallback recovery"

	resolvfile="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}"
	[ -f "$resolvfile" ] || resolvfile=''

	if dnsmasq_state_matches "" "0" "$resolvfile" ""; then
		dns_cleanup_backup_files
		log "dnsmasq fallback state already active"
		return 0
	fi

	if ! dns_stage_fallback_state "$resolvfile"; then
		dns_revert_staged_changes
		return 1
	fi
	dns_commit_dhcp_and_restart "dnsmasq restart failed during fallback restore" || return 1
	dns_cleanup_backup_files
	return 0
}

# Restore from already parsed backup state.
dns_restore_loaded_backup_state() {
	if dns_expected_state_matches_current; then
		dns_cleanup_backup_files
		log "dnsmasq settings already restored"
		return 0
	fi

	if ! dns_stage_expected_restore_state; then
		dns_revert_staged_changes
		return 1
	fi
	dns_commit_dhcp_and_restart "dnsmasq restart failed during restore" || return 1

	dns_cleanup_backup_files
	log "dnsmasq settings restored"
	return 0
}

# Restore from backup file, or fallback if the file is invalid.
dns_restore_backup_file_or_fallback() {
	local backup_path="$1"

	if ! dns_backup_read_expected_state "$backup_path"; then
		warn "dnsmasq backup state invalid, applying fallback recovery"
		dns_restore_fallback
		return $?
	fi

	dns_restore_loaded_backup_state
}

# Cleanup path when no backup is available.
dns_restore_without_backup() {
	local mihomo_dns_target="$1"

	if dns_current_state_looks_hijacked "$mihomo_dns_target"; then
		warn "dnsmasq recovery backup unavailable while Mihomo DNS still appears active; applying fallback recovery"
		dns_restore_fallback
		return $?
	fi

	log "No dnsmasq recovery backup found, skipping restore"
	return 0
}

# Apply dnsmasq upstream hijack to Mihomo DNS, creating recovery backups first.
dns_setup() {
	local dns_target

	dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN")"
	if dnsmasq_state_matches "0" "1" "" "$dns_target"; then
		if dns_backup_exists; then
			log "dnsmasq already configured to use Mihomo DNS $dns_target; reusing existing recovery backup state"
		else
			warn "dnsmasq already configured to use Mihomo DNS $dns_target, but no recovery backup is active; fallback restore will be used if cleanup is needed"
		fi
		return 0
	fi

	if ! dns_runtime_backup_exists; then
		if ! dns_backup_state; then
			err "Failed to persist dnsmasq backup state"
			return 1
		fi
	fi

	if ! dns_stage_hijack_state "$dns_target"; then
		dns_revert_staged_changes
		return 1
	fi
	dns_commit_dhcp_and_restart "dnsmasq restart failed after DNS apply" || return 1

	log "dnsmasq configured to use Mihomo DNS $dns_target"
	return 0
}

# Restore dnsmasq from runtime/persistent backup or safe fallback.
dns_restore() {
	local backup_path="" mihomo_dns_target=""

	if [ -n "${MIHOMO_DNS_LISTEN:-}" ]; then
		mihomo_dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN" 2>/dev/null || true)"
	fi

	backup_path="$(dns_backup_source_file 2>/dev/null || true)"
	if [ -z "$backup_path" ]; then
		dns_restore_without_backup "$mihomo_dns_target"
		return $?
	fi

	dns_restore_backup_file_or_fallback "$backup_path"
}
