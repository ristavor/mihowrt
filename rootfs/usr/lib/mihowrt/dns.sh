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

dns_backup_file_valid() {
	local backup_path="$1"

	[ -f "$backup_path" ] || return 1

	grep -q '^DNSMASQ_BACKUP=1$' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_CACHESIZE=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_NORESOLV=' "$backup_path" 2>/dev/null || return 1
	grep -q '^ORIG_RESOLVFILE=' "$backup_path" 2>/dev/null || return 1
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
	local backup_path="$1"
	local line server tab="" server_sep=""

	dns_backup_file_valid "$backup_path" || return 1

	DNS_BACKUP_EXPECTED_CACHESIZE=''
	DNS_BACKUP_EXPECTED_NORESOLV=''
	DNS_BACKUP_EXPECTED_RESOLVFILE=''
	DNS_BACKUP_EXPECTED_TARGET_NORESOLV=''
	DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE=''
	DNS_BACKUP_EXPECTED_SERVERS=''
	DNS_BACKUP_EXPECTED_HAS_SERVERS=0
	tab="$(printf '\t')"

	while IFS= read -r line; do
		case "$line" in
			DNSMASQ_BACKUP=*)
				:
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
					DNS_BACKUP_EXPECTED_SERVERS="${DNS_BACKUP_EXPECTED_SERVERS}${server_sep}${server}"
					server_sep="$tab"
					DNS_BACKUP_EXPECTED_HAS_SERVERS=1
				fi
				;;
		esac
	done < "$backup_path"

	DNS_BACKUP_EXPECTED_TARGET_NORESOLV="$DNS_BACKUP_EXPECTED_NORESOLV"
	DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE="$DNS_BACKUP_EXPECTED_RESOLVFILE"
	if [ -z "$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" ] &&
		[ "$DNS_BACKUP_EXPECTED_HAS_SERVERS" -eq 0 ] &&
		[ -f "${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" ]; then
		DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}"
		[ "$DNS_BACKUP_EXPECTED_NORESOLV" = "1" ] || DNS_BACKUP_EXPECTED_TARGET_NORESOLV='0'
	fi
}

dns_backup_file_matches_current() {
	local backup_path="$1"

	dns_backup_read_expected_state "$backup_path" || return 1
	dnsmasq_state_matches \
		"$DNS_BACKUP_EXPECTED_CACHESIZE" \
		"$DNS_BACKUP_EXPECTED_TARGET_NORESOLV" \
		"$DNS_BACKUP_EXPECTED_TARGET_RESOLVFILE" \
		"$DNS_BACKUP_EXPECTED_SERVERS"
}

dns_current_state_looks_hijacked() {
	local current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""
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

	return 0
}

dns_persist_backup_recovery_needed() {
	dns_persist_backup_exists || return 1
	dns_persist_backup_valid || return 1
	dns_current_state_looks_hijacked || return 1
	dns_backup_file_matches_current "$DNS_BACKUP_FILE" && return 1
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
	local backup_tmp persist_tmp runtime_backup="" server

	runtime_backup="$(dns_runtime_backup_file)"
	ensure_dir "$(dirname "$runtime_backup")"
	ensure_dir "$PKG_PERSIST_DIR"
	backup_tmp="${runtime_backup}.tmp.$$"
	persist_tmp="${DNS_BACKUP_FILE}.tmp.$$"

	: > "$backup_tmp" || return 1

	{
		printf 'DNSMASQ_BACKUP=1\n'
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

	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].cachesize 2>/dev/null || true
	uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || return 1

	if [ -n "$resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile" 2>/dev/null || return 1
	fi

	uci commit dhcp || return 1
	dns_restart_service || warn "dnsmasq restart failed during fallback restore"
	dns_cleanup_backup_files
	return 0
}

dns_setup() {
	local dns_target

	dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN")"
	if dnsmasq_state_matches "0" "1" "" "$dns_target"; then
		if dns_backup_exists; then
			log "Previous shutdown not clean. Reusing existing dnsmasq backup state"
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

	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	uci add_list dhcp.@dnsmasq[0].server="$dns_target" || return 1
	uci set dhcp.@dnsmasq[0].cachesize='0' || return 1
	uci set dhcp.@dnsmasq[0].noresolv='1' || return 1
	uci commit dhcp || return 1

	if ! dns_restart_service; then
		err "dnsmasq restart failed after DNS apply"
		return 1
	fi

	log "dnsmasq configured to use Mihomo DNS $dns_target"
	return 0
}

dns_restore() {
	local backup_path="" server="" line=""

	backup_path="$(dns_backup_source_file 2>/dev/null || true)"
	if [ -z "$backup_path" ]; then
		if dns_current_state_looks_hijacked; then
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

	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	while IFS= read -r line; do
		case "$line" in
			ORIG_SERVER=*)
				server="${line#ORIG_SERVER=}"
				if [ -n "$server" ]; then
					uci add_list dhcp.@dnsmasq[0].server="$server" || return 1
				fi
				;;
		esac
	done < "$backup_path"

	if [ -n "$DNS_BACKUP_EXPECTED_CACHESIZE" ]; then
		uci set dhcp.@dnsmasq[0].cachesize="$DNS_BACKUP_EXPECTED_CACHESIZE" 2>/dev/null || return 1
	else
		uci -q delete dhcp.@dnsmasq[0].cachesize 2>/dev/null || true
	fi

	if [ -n "$DNS_BACKUP_EXPECTED_NORESOLV" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$DNS_BACKUP_EXPECTED_NORESOLV" 2>/dev/null || return 1
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
	fi

	if [ -n "$DNS_BACKUP_EXPECTED_RESOLVFILE" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$DNS_BACKUP_EXPECTED_RESOLVFILE" 2>/dev/null || return 1
	elif [ "$DNS_BACKUP_EXPECTED_HAS_SERVERS" -eq 0 ] && [ -f "${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="${DNS_AUTO_RESOLVFILE:-/tmp/resolv.conf.d/resolv.conf.auto}" 2>/dev/null || return 1
		[ "$DNS_BACKUP_EXPECTED_NORESOLV" = "1" ] || uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || return 1
	fi

	uci commit dhcp || return 1
	dns_restart_service || warn "dnsmasq restart failed during restore"

	dns_cleanup_backup_files
	log "dnsmasq settings restored"
	return 0
}
