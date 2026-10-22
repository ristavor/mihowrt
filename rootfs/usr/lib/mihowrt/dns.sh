#!/bin/ash

# Point dnsmasq at Mihomo with a conf-dir file. Nothing in UCI changes, so
# there is nothing to back up: removing the file (or a reboot, it lives in
# tmpfs) restores the user's DNS setup.

# -X prints real names (cfg01411c) for anonymous sections, as dnsmasq's init
# script uses them for the default confdir.
dns_sections() {
	uci -q -X show dhcp 2>/dev/null | sed -n 's/^dhcp\.\([^.=]*\)=dnsmasq$/\1/p'
}

dns_confdirs() {
	local section="" dir=""

	for section in $(dns_sections); do
		dir="$(uci -q get "dhcp.$section.confdir" 2>/dev/null)" || dir=""
		[ -n "$dir" ] || dir="/tmp/dnsmasq.$section.d"
		printf '%s\n' "${dir%%,*}"
	done
}

# DNS servers of the WAN interfaces, as learned by netifd (provider or custom).
dns_wan_servers() {
	[ -r "$DNS_AUTO_RESOLVFILE" ] || return 0
	awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ && $2 !~ /%/ { print $2 }' "$DNS_AUTO_RESOLVFILE"
}

# Plain DNS names only: anything else could inject dnsmasq syntax.
dns_host_name() {
	case "$1" in
	'' | *[!A-Za-z0-9.-]* | .* | *..*) return 1 ;;
	esac
	is_ipv4 "$1" && return 1
	printf '%s\n' "$1"
}

# Hosts that must resolve even when Mihomo is broken: NTP (TLS needs a correct
# clock) and the subscription server (to fetch a working config).
dns_bypass_hosts() {
	local host=""

	if [ "${BYPASS_NTP:-1}" = "1" ]; then
		for host in $(uci -q get system.ntp.server 2>/dev/null); do
			dns_host_name "$host"
		done
	fi
	if [ "${BYPASS_SUBSCRIPTION_DNS:-1}" = "1" ] && [ -n "${SUBSCRIPTION_URL:-}" ]; then
		host="$(url_host "$SUBSCRIPTION_URL")"
		dns_host_name "$host"
	fi
}

dns_render() {
	local out="$1" host="" server="" servers=""

	servers="$(dns_wan_servers)"
	{
		printf 'no-resolv\n'
		printf 'server=127.0.0.1#%s\n' "$MIHOMO_DNS_PORT"
		[ -z "$servers" ] || for host in $(dns_bypass_hosts | sort -u); do
			for server in $servers; do
				printf 'server=/%s/%s\n' "$host" "$server"
			done
		done
	} >"$out"
}

dns_restart_dnsmasq() {
	[ -x /etc/init.d/dnsmasq ] || return 0
	/etc/init.d/dnsmasq restart 9>&- >/dev/null 2>&1
}

dns_apply() {
	settings_require || return 1

	local dir="" tmp="" changed=0

	tmp="$PKG_TMP_DIR/dns.conf.$$"
	ensure_dir "$PKG_TMP_DIR" || return 1
	dns_render "$tmp" || {
		rm -f "$tmp"
		return 1
	}
	for dir in $(dns_confdirs); do
		cmp -s "$tmp" "$dir/$DNS_CONF_NAME" && continue
		if ! { ensure_dir "$dir" && cp "$tmp" "$dir/$DNS_CONF_NAME"; }; then
			rm -f "$tmp"
			err "Failed to write $dir/$DNS_CONF_NAME"
			return 1
		fi
		changed=1
	done
	rm -f "$tmp"
	[ "$changed" -eq 1 ] || return 0
	dns_restart_dnsmasq || {
		err "dnsmasq restart failed"
		return 1
	}
	log "dnsmasq now uses Mihomo DNS 127.0.0.1#$MIHOMO_DNS_PORT"
}

dns_cleanup() {
	local file="" removed=0

	for file in $(dns_confdirs | sed "s|\$|/$DNS_CONF_NAME|") /tmp/dnsmasq*.d/"$DNS_CONF_NAME"; do
		[ -e "$file" ] || continue
		rm -f "$file"
		removed=1
	done
	[ "$removed" -eq 1 ] || return 0
	dns_restart_dnsmasq
	log "dnsmasq DNS restored"
}

# Interface updates change both DNS servers and connected/delegated routes.
net_refresh() {
	# The marker exists only while policy is applied to a live Mihomo.
	[ -f "$RUNNING_MARKER" ] && service_running || return 0
	settings_load || return 1
	local rc=0
	dns_apply || rc=1
	# New prefixes must reach nft even when dnsmasq could not be updated.
	nft_apply || rc=1
	return "$rc"
}

dns_custom_servers() {
	uci -q show dhcp 2>/dev/null | sed -n "s/^dhcp\.[^.]*\.server='\(.*\)'$/\1/p" | tr "'" ' '
}
