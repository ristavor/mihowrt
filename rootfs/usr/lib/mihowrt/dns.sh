#!/bin/ash

dns_backup_exists() {
	[ -f "$DNS_BACKUP_FILE" ]
}

dns_backup_valid() {
	[ -f "$DNS_BACKUP_FILE" ] || return 1

	grep -q '^DNSMASQ_BACKUP=1$' "$DNS_BACKUP_FILE" 2>/dev/null || return 1
	grep -q '^ORIG_CACHESIZE=' "$DNS_BACKUP_FILE" 2>/dev/null || return 1
	grep -q '^ORIG_NORESOLV=' "$DNS_BACKUP_FILE" 2>/dev/null || return 1
	grep -q '^ORIG_RESOLVFILE=' "$DNS_BACKUP_FILE" 2>/dev/null || return 1
}

dns_redirect_active() {
	[ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]
}

dns_cleanup_backup_files() {
	rm -f "$DNS_BACKUP_FILE"
}

dns_backup_state() {
	local backup_tmp server

	ensure_dir "$PKG_PERSIST_DIR"
	backup_tmp="${DNS_BACKUP_FILE}.tmp.$$"

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
		rm -f "$backup_tmp"
		return 1
	}
	mv -f "$backup_tmp" "$DNS_BACKUP_FILE" || {
		rm -f "$backup_tmp"
		return 1
	}

	return 0
}

dns_restore_fallback() {
	local resolvfile

	warn "dnsmasq backup state missing, applying fallback recovery"

	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].cachesize 2>/dev/null || true
	uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null || true

	resolvfile='/tmp/resolv.conf.d/resolv.conf.auto'
	if [ -f "$resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$resolvfile" 2>/dev/null || true
	fi

	uci commit dhcp || return 1
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || warn "dnsmasq restart failed during fallback restore"
	dns_cleanup_backup_files
	return 0
}

dns_recovery_needed() {
	dns_backup_exists || dns_redirect_active
}

dns_setup() {
	local dns_target

	if ! dns_backup_exists; then
		if ! dns_backup_state; then
			err "Failed to persist dnsmasq backup state"
			return 1
		fi
	else
		log "Previous shutdown not clean. Reusing existing dnsmasq backup state"
	fi

	dns_target="$(normalize_dns_server_target "$MIHOMO_DNS_LISTEN")"
	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	uci add_list dhcp.@dnsmasq[0].server="$dns_target" || return 1
	uci set dhcp.@dnsmasq[0].cachesize='0' || return 1
	uci set dhcp.@dnsmasq[0].noresolv='1' || return 1
	uci commit dhcp || return 1

	if ! /etc/init.d/dnsmasq restart >/dev/null 2>&1; then
		err "dnsmasq restart failed after DNS apply"
		return 1
	fi

	log "dnsmasq configured to use Mihomo DNS $dns_target"
	return 0
}

dns_restore() {
	local orig_cachesize orig_noresolv orig_resolvfile server has_servers=0 line

	if ! dns_backup_exists; then
		if dns_redirect_active; then
			return dns_restore_fallback
		fi
		log "No dnsmasq backup state found, skipping restore"
		return 0
	fi
	if ! dns_backup_valid; then
		warn "dnsmasq backup state invalid, applying fallback recovery"
		return dns_restore_fallback
	fi

	orig_cachesize=''
	orig_noresolv=''
	orig_resolvfile=''

	uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
	uci -q delete dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true
	while IFS= read -r line; do
		case "$line" in
			DNSMASQ_BACKUP=*)
				:
				;;
			ORIG_CACHESIZE=*)
				orig_cachesize="${line#ORIG_CACHESIZE=}"
				;;
			ORIG_NORESOLV=*)
				orig_noresolv="${line#ORIG_NORESOLV=}"
				;;
			ORIG_RESOLVFILE=*)
				orig_resolvfile="${line#ORIG_RESOLVFILE=}"
				;;
			ORIG_SERVER=*)
				server="${line#ORIG_SERVER=}"
				if [ -n "$server" ]; then
					uci add_list dhcp.@dnsmasq[0].server="$server"
					has_servers=1
				fi
				;;
		esac
	done < "$DNS_BACKUP_FILE"

	if [ -n "$orig_cachesize" ]; then
		uci set dhcp.@dnsmasq[0].cachesize="$orig_cachesize" 2>/dev/null
	else
		uci -q delete dhcp.@dnsmasq[0].cachesize 2>/dev/null || true
	fi

	if [ -n "$orig_noresolv" ]; then
		uci set dhcp.@dnsmasq[0].noresolv="$orig_noresolv" 2>/dev/null
	else
		uci -q delete dhcp.@dnsmasq[0].noresolv 2>/dev/null || true
	fi

	if [ -n "$orig_resolvfile" ]; then
		uci set dhcp.@dnsmasq[0].resolvfile="$orig_resolvfile" 2>/dev/null
	elif [ "$has_servers" -eq 0 ] && [ -f /tmp/resolv.conf.d/resolv.conf.auto ]; then
		uci set dhcp.@dnsmasq[0].resolvfile='/tmp/resolv.conf.d/resolv.conf.auto' 2>/dev/null
		[ "$orig_noresolv" = "1" ] || uci set dhcp.@dnsmasq[0].noresolv='0' 2>/dev/null
	fi

	uci commit dhcp || return 1
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || warn "dnsmasq restart failed during restore"

	dns_cleanup_backup_files
	log "dnsmasq settings restored"
	return 0
}
