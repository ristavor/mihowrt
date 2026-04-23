#!/bin/ash

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

dns_backup_text_has_controls() {
	printf '%s' "$1" | grep -q '[[:cntrl:]]'
}

dns_backup_server_atom_valid() {
	printf '%s' "$1" | grep -qE '^(\[[A-Za-z0-9._:%@:-]+\]|[A-Za-z0-9._:%@:-]+)$'
}

dns_backup_server_selector_valid() {
	printf '%s' "$1" | grep -qE '^[#A-Za-z0-9._*:/-]+$'
}

dns_backup_server_target_valid() {
	local value="$1"
	local host="" port=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls "$value" && return 1
	printf '%s' "$value" | grep -q '[[:space:]]' && return 1

	case "$value" in
		*#*)
			host="${value%#*}"
			port="${value##*#}"
			[ -n "$host" ] || return 1
			case "$host" in
				*'#'*|*/*)
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

dns_backup_server_value_valid() {
	local value="$1"
	local rest="" prefix="" target=""

	[ -n "$value" ] || return 1
	dns_backup_text_has_controls "$value" && return 1
	printf '%s' "$value" | grep -q '[[:space:]]' && return 1

	case "$value" in
		/*)
			rest="${value#/}"
			case "$rest" in
				*/*)
					:
					;;
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

dns_backup_parsed_state_valid() {
	if [ -n "$DNS_BACKUP_EXPECTED_CACHESIZE" ] && ! is_uint "$DNS_BACKUP_EXPECTED_CACHESIZE"; then
		return 1
	fi

	case "$DNS_BACKUP_EXPECTED_NORESOLV" in
		''|0|1)
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

dns_backup_parse_expected_state() {
	local backup_path="$1"
	local line server tab="" server_sep=""

	[ -f "$backup_path" ] || return 1

	grep -q '^DNSMASQ_BACKUP=1$' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_CACHESIZE=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_NORESOLV=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_RESOLVFILE=' "$backup_path" 2>/dev/null || return 1

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
			DNSMASQ_BACKUP=*)
				:
				;;
			MIHOMO_DNS_TARGET=*)
				DNS_BACKUP_MIHOMO_TARGET="${line#MIHOMO_DNS_TARGET=}"
				;;
			ORIG_CACHESIZE=*)
				DNS_BACKUP_EXPECTED_CACHESIZE="${line#ORIG_CACHESIZE=}"
				;;
			ORIG_NORESOLV=*)
				DNS_BACKUP_EXPECTED_NORESOLV="${line#ORIG_NORESOLV=}"
				;;
			ORIG_RESOLVFILE=*)
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
	done < "$backup_path"

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

dns_backup_file_valid() {
	dns_backup_parse_expected_state "$1" >/dev/null 2>&1
}

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

dns_backup_read_expected_state() {
	dns_backup_parse_expected_state "$1"
}

dns_current_state_looks_hijacked() {
	local expected_target="${1:-}" current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""
	local current_host="" current_port="" tab=""

	current_cachesize="$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
	current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
	current_resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true)"
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
			127.0.0.1|::1|localhost)
				:
				;;
			*)
				return 1
				;;
		esac
	fi

	return 0
}

dns_runtime_mihomo_target() {
	local config_json="" config_errors="" mihomo_dns_listen="" snapshot_json=""

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

	config_errors="$(printf '%s\n' "$config_json" | jq -r '.errors[]?' 2>/dev/null || true)"
	[ -z "$config_errors" ] || return 1

	mihomo_dns_listen="$(printf '%s\n' "$config_json" | jq -r '.mihomo_dns_listen // ""' 2>/dev/null || true)"
	[ -n "$mihomo_dns_listen" ] || return 1

	normalize_dns_server_target "$mihomo_dns_listen"
}

dns_persist_backup_recovery_needed() {
	local expected_target=""

	dns_persist_backup_exists || return 1
	dns_backup_read_expected_state "$DNS_BACKUP_FILE" || return 1
	expected_target="$DNS_BACKUP_MIHOMO_TARGET"
	[ -n "$expected_target" ] || expected_target="$(dns_runtime_mihomo_target 2>/dev/null || true)"
	dns_current_state_looks_hijacked "$expected_target" || return 1
	dnsmasq_state_matches \
		"$DNS_BACKUP_EXPECTED_CACHESIZE" \
		"$DNS_BACKUP_EXPECTED_TARGET_NORESOLV" \
		"$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" \
		"$DNS_BACKUP_EXPECTED_SERVERS" && return 1
	return 0
}

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

	: > "$backup_tmp" || return 1

	{
		printf 'DNSMASQ_BACKUP=1\n'
		printf 'MIHOMO_DNS_TARGET=%s\n' "$mihomo_dns_target"
		printf 'ORIG_CACHESIZE=%s\n' "$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null)"
		printf 'ORIG_NORESOLV=%s\n' "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)"
		printf 'ORIG_RESOLVFILE=%s\n' "$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null)"
		uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | while IFS= read -r server; do
			printf 'ORIG_SERVER=%s\n' "$server"
		done
	} >> "$backup_tmp" || {
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

dns_revert_staged_changes() {
	uci revert dhcp >/dev/null 2>&1 || true
}

dns_delete_option_if_present() {
	local option="$1"

	uci -q get "$option" >/dev/null 2>&1 || return 0
	uci -q delete "$option" 2>/dev/null
}

dns_restore_fallback() {
	local resolvfile=""

	warn "dnsmasq backup state unavailable, applying fallback recovery"

	resolvfile="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}"
	if [ -f "$resolvfile" ]; then
		:
	else
		resolvfile=''
	fi

	if dnsmasq_state_matches "" "0" "$resolvfile" ""; then
		dns_cleanup_backup_files
		log "dnsmasq fallback state already active"
		return 0
	fi

	dns_delete_option_if_present dhcp.@dnsmasq[0].server || {
		dns_revert_staged_changes
		return 1
	}
	dns_delete_option_if_present dhcp.@dnsmasq[0].resolvfile || {
		dns_revert_staged_changes
		return 1
	}
	dns_delete_option_if_present dhcp.@dnsmasq[0].cachesize || {
		dns_revert_staged_changes
		return 1
	}
	uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || {
		dns_revert_staged_changes
		return 1
	}

	if [ -n "$resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile" 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
	fi

	uci commit dhcp || {
		dns_revert_staged_changes
		return 1
	}
	if ! dns_restart_service; then
		err "dnsmasq restart failed during fallback restore"
		return 1
	fi
	dns_cleanup_backup_files
	return 0
}

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

	dns_delete_option_if_present dhcp.@dnsmasq[0].server || {
		dns_revert_staged_changes
		return 1
	}
	dns_delete_option_if_present dhcp.@dnsmasq[0].resolvfile || {
		dns_revert_staged_changes
		return 1
	}
	uci add_list dhcp.@dnsmasq[0].server="$dns_target" || {
		dns_revert_staged_changes
		return 1
	}
	uci set dhcp.@dnsmasq[0].cachesize='0' || {
		dns_revert_staged_changes
		return 1
	}
	uci set dhcp.@dnsmasq[0].noresolv='1' || {
		dns_revert_staged_changes
		return 1
	}
	uci commit dhcp || {
		dns_revert_staged_changes
		return 1
	}

	if ! dns_restart_service; then
		err "dnsmasq restart failed after DNS apply"
		return 1
	fi

	log "dnsmasq configured to use Mihomo DNS $dns_target"
	return 0
}

dns_restore() {
	local backup_path="" server="" line="" mihomo_dns_target=""

	if [ -n "${MIHOMO_DNS_LISTEN:-}" ]; then
		mihomo_dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN" 2>/dev/null || true)"
	fi

	backup_path="$(dns_backup_source_file 2>/dev/null || true)"
	if [ -z "$backup_path" ]; then
		if dns_current_state_looks_hijacked "$mihomo_dns_target"; then
			warn "dnsmasq recovery backup unavailable while Mihomo DNS still appears active; applying fallback recovery"
			dns_restore_fallback
			return $?
		fi
		log "No dnsmasq recovery backup found, skipping restore"
		return 0
	fi

	if ! dns_backup_read_expected_state "$backup_path"; then
		warn "dnsmasq backup state invalid, applying fallback recovery"
		dns_restore_fallback
		return $?
	fi

	if dnsmasq_state_matches \
		"$DNS_BACKUP_EXPECTED_CACHESIZE" \
		"$DNS_BACKUP_EXPECTED_TARGET_NORESOLV" \
		"$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" \
		"$DNS_BACKUP_EXPECTED_SERVERS"; then
		dns_cleanup_backup_files
		log "dnsmasq settings already restored"
		return 0
	fi

	dns_delete_option_if_present dhcp.@dnsmasq[0].server || {
		dns_revert_staged_changes
		return 1
	}
	dns_delete_option_if_present dhcp.@dnsmasq[0].resolvfile || {
		dns_revert_staged_changes
		return 1
	}
	while IFS= read -r line; do
		case "$line" in
			ORIG_SERVER=*)
				server="${line#ORIG_SERVER=}"
				if [ -n "$server" ]; then
					uci add_list dhcp.@dnsmasq[0].server="$server" || {
						dns_revert_staged_changes
						return 1
					}
				fi
				;;
		esac
	done < "$backup_path"

	if [ -n "$DNS_BACKUP_EXPECTED_CACHESIZE" ]; then
		uci set dhcp.@dnsmasq[0].cachesize="$DNS_BACKUP_EXPECTED_CACHESIZE" 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
	else
		dns_delete_option_if_present dhcp.@dnsmasq[0].cachesize || {
			dns_revert_staged_changes
			return 1
		}
	fi

	if [ -n "$DNS_BACKUP_EXPECTED_NORESOLV" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$DNS_BACKUP_EXPECTED_NORESOLV" 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
	else
		dns_delete_option_if_present dhcp.@dnsmasq[0].noresolv || {
			dns_revert_staged_changes
			return 1
		}
	fi

	if [ -n "$DNS_BACKUP_EXPECTED_RESOLVFILE" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_BACKUP_EXPECTED_RESOLVFILE" 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
	elif [ "$DNS_BACKUP_EXPECTED_HAS_SERVERS" -eq 0 ] && [ -f "${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
		[ "$DNS_BACKUP_EXPECTED_NORESOLV" = "1" ] || uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || {
			dns_revert_staged_changes
			return 1
		}
	fi

	uci commit dhcp || {
		dns_revert_staged_changes
		return 1
	}
	if ! dns_restart_service; then
		err "dnsmasq restart failed during restore"
		return 1
	fi

	dns_cleanup_backup_files
	log "dnsmasq settings restored"
	return 0
}
