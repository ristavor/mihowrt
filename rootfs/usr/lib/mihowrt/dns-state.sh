#!/bin/ash

dns_flatten_lines() {
	local line out="" sep="" tab=""

	tab="$(printf '\t')"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		out="${out}${sep}${line}"
		sep="$tab"
	done

	printf '%s' "$out"
}

dns_current_servers_flat() {
	uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | dns_flatten_lines
}

dnsmasq_state_matches() {
	local expected_cachesize="$1"
	local expected_noresolv="$2"
	local expected_resolvfile="$3"
	local expected_servers="$4"
	local current_cachesize="" current_noresolv="" current_resolvfile="" current_servers=""

	current_cachesize="$(uci -q get dhcp.@dnsmasq[0].cachesize 2>/dev/null || true)"
	current_noresolv="$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || true)"
	current_resolvfile="$(uci -q get dhcp.@dnsmasq[0].resolvfile 2>/dev/null || true)"
	current_servers="$(dns_current_servers_flat)"

	[ "$current_cachesize" = "$expected_cachesize" ] || return 1
	[ "$current_noresolv" = "$expected_noresolv" ] || return 1
	[ "$current_resolvfile" = "$expected_resolvfile" ] || return 1
	[ "$current_servers" = "$expected_servers" ]
}
