#!/bin/ash

# nftables policy for IPv4 and IPv6. The whole table is rendered into one file
# and replaced atomically with a single `nft -f` (one kernel transaction:
# packets see the old or the new ruleset, never none). An identical ruleset
# is not applied again.

NFT_FILE=""

nft_line() {
	printf '%s\n' "$*" >>"$NFT_FILE"
}

nft_rule() {
	local chain="$1"
	shift
	nft_line "add rule inet $NFT_TABLE_NAME $chain $*"
}

# Load plain addresses of one resolved list file into a set (512 per line).
nft_fill_set() {
	local set="$1" file="$2"

	[ -s "$file" ] || return 0
	{ grep -v ';' "$file" || true; } | awk -v t="$NFT_TABLE_NAME" -v s="$set" '
		{ chunk = chunk (n ? "," : "") $0; n++ }
		n == 512 { print "add element inet " t " " s " { " chunk " }"; chunk = ""; n = 0 }
		END { if (n) print "add element inet " t " " s " { " chunk " }" }
	' >>"$NFT_FILE"
}

nft_set_count() {
	[ -s "$1" ] || {
		echo 0
		return 0
	}
	grep -vc ';' "$1" || true
}

# True when a port spec (443, 400-500, 80,443) contains 443.
nft_ports_include_443() {
	local item="" old_ifs="$IFS" found=1

	IFS=','
	for item in $1; do
		case "$item" in
		*-*) [ "${item%-*}" -le 443 ] && [ "${item#*-}" -ge 443 ] && found=0 ;;
		443) found=0 ;;
		esac
	done
	IFS="$old_ifs"
	return "$found"
}

# Emit one rule per port-scoped entry: "<addr>;<ports>" or ";<ports>".
# $1 chain, $2 file, $3 family keyword (ip|ip6), $4 field (daddr|saddr),
# $5 action, $6 "quic" to emit UDP/443 rejects instead of the action.
nft_port_rules() {
	local chain="$1" file="$2" fam="$3" field="$4" action="$5" quic="${6:-}"
	local entry="" addr="" ports="" match=""

	[ -s "$file" ] || return 0
	{ grep ';' "$file" || true; } | while IFS= read -r entry; do
		addr="${entry%%;*}"
		ports="${entry#*;}"
		if [ -n "$addr" ]; then
			match="$fam $field $addr"
		else
			match="meta nfproto $([ "$fam" = ip ] && echo ipv4 || echo ipv6)"
		fi
		if [ "$quic" = "quic" ]; then
			if nft_ports_include_443 "$ports"; then
				nft_rule "$chain" "$match udp dport 443 reject"
			fi
		else
			nft_rule "$chain" "$match meta l4proto { tcp, udp } th dport { $ports } $action"
		fi
	done
}


nft_render_base() {
	local iface="" t="$NFT_TABLE_NAME" set=""

	nft_line "add table inet $t"
	nft_line "delete table inet $t"
	nft_line "add table inet $t"
	for set in proxy_dst proxy_src direct_dst direct_src localv4; do
		nft_line "add set inet $t $set { type ipv4_addr; flags interval; auto-merge; }"
	done
	for set in proxy_dst6 proxy_src6 direct_dst6 direct_src6 localv6; do
		nft_line "add set inet $t $set { type ipv6_addr; flags interval; auto-merge; }"
	done
	nft_line "add set inet $t source_ifaces { type ifname; }"
	# Filled only while the subscription downloads (router traffic only).
	nft_line "add set inet $t bypass_dst { type ipv4_addr; flags timeout; }"
	nft_line "add set inet $t bypass_dst6 { type ipv6_addr; flags timeout; }"
	nft_line "add element inet $t localv4 { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3 }"
	nft_line "add element inet $t localv6 { ::/127, fe80::/10, fc00::/7, ff00::/8 }"
	for iface in $SOURCE_INTERFACES; do
		nft_line "add element inet $t source_ifaces { \"$iface\" }"
	done
	nft_line "add chain inet $t dns_hijack { type nat hook prerouting priority dstnat; policy accept; }"
	nft_line "add chain inet $t mangle_prerouting { type filter hook prerouting priority mangle; policy accept; }"
	nft_line "add chain inet $t prerouting_policy"
	nft_line "add chain inet $t mangle_output { type route hook output priority mangle; policy accept; }"
	nft_line "add chain inet $t proxy_redirect { type filter hook prerouting priority dstnat; policy accept; }"
}

# Shared guards: never touch local, already-marked, DNS or NTP traffic.
nft_render_guards() {
	local chain="$1"

	nft_rule "$chain" "fib daddr type local return"
	nft_rule "$chain" "ip daddr @localv4 return"
	nft_rule "$chain" "ip6 daddr @localv6 return"
	nft_rule "$chain" "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK return"
	# NTP to fake-IP addresses is a domain the user routes via Mihomo.
	if [ "$BYPASS_NTP" = "1" ]; then
		nft_rule "$chain" "meta nfproto ipv6 udp dport 123 return"
		nft_rule "$chain" "ip daddr != $FAKEIP_RANGE udp dport 123 return"
	fi
	return 0
}

nft_render_netbird_output() {
	local m0="" dp=""

	m0="$(printf '0x%x' "$NETBIRD_MARK")"
	dp="$(printf '0x%x, 0x%x, 0x%x, 0x%x, 0x%x' $((NETBIRD_MARK | 0x10)) $((NETBIRD_MARK | 0x11)) $((NETBIRD_MARK | 0x20)) $((NETBIRD_MARK | 0x21)) $((NETBIRD_MARK | 0x22)))"
	if [ "$NETBIRD_PROXY" = "1" ]; then
		# Control-plane mark covers management, signal, relay, ICE and WireGuard
		# transport; dataplane marks and replies to inbound flows stay direct.
		nft_rule mangle_output "ct direction reply meta mark $m0 return"
		nft_rule mangle_output "meta mark { $dp } return"
		nft_rule mangle_output "ct direction original meta mark $m0 meta l4proto { tcp, udp } $NFT_MARK_SET accept"
	else
		nft_rule mangle_output "meta mark { $m0, $dp } return"
	fi
}

# Mark traffic selected by one list kind in one chain.
# $1 chain, $2 v4 file, $3 v6 file, $4 field, $5 set base name.
nft_render_list_marks() {
	local chain="$1" f4="$2" f6="$3" field="$4" set="$5"

	if [ "$DISABLE_QUIC" = "1" ]; then
		[ "$(nft_set_count "$f4")" -gt 0 ] && nft_rule "$chain" "ip $field @$set udp dport 443 reject"
		[ "$(nft_set_count "$f6")" -gt 0 ] && nft_rule "$chain" "ip6 $field @${set}6 udp dport 443 reject"
		nft_port_rules "$chain" "$f4" ip "$field" "" quic
		nft_port_rules "$chain" "$f6" ip6 "$field" "" quic
	fi
	[ "$(nft_set_count "$f4")" -gt 0 ] && nft_rule "$chain" "ip $field @$set meta l4proto { tcp, udp } $NFT_MARK_SET"
	[ "$(nft_set_count "$f6")" -gt 0 ] && nft_rule "$chain" "ip6 $field @${set}6 meta l4proto { tcp, udp } $NFT_MARK_SET"
	nft_port_rules "$chain" "$f4" ip "$field" "$NFT_MARK_SET"
	nft_port_rules "$chain" "$f6" ip6 "$field" "$NFT_MARK_SET"
}

nft_render_direct_returns() {
	local chain="$1" f4="$2" f6="$3"

	[ "$(nft_set_count "$f4")" -gt 0 ] && nft_rule "$chain" "ip daddr @direct_dst return"
	[ "$(nft_set_count "$f6")" -gt 0 ] && nft_rule "$chain" "ip6 daddr @direct_dst6 return"
	nft_port_rules "$chain" "$f4" ip daddr return
	nft_port_rules "$chain" "$f6" ip6 daddr return
}

# Devices always direct (proxy-first). With fake-IP DNS their domains would
# resolve to fake addresses that only Mihomo can reach, so they are skipped.
nft_render_direct_devices() {
	local chain="$1" f4="$2" f6="$3"

	[ "$DNS_MODE" = "fake-ip" ] && return 0
	[ "$(nft_set_count "$f4")" -gt 0 ] && nft_rule "$chain" "ip saddr @direct_src return"
	[ "$(nft_set_count "$f6")" -gt 0 ] && nft_rule "$chain" "ip6 saddr @direct_src6 return"
	nft_port_rules "$chain" "$f4" ip saddr return
	nft_port_rules "$chain" "$f6" ip6 saddr return
}

nft_render_fakeip() {
	local chain="$1"

	[ "$DISABLE_QUIC" = "1" ] && nft_rule "$chain" "ip daddr $FAKEIP_RANGE udp dport 443 reject"
	nft_rule "$chain" "ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } $NFT_MARK_SET"
}

nft_render_catch_all() {
	local chain="$1"

	[ "$DISABLE_QUIC" = "1" ] && nft_rule "$chain" "udp dport 443 reject"
	nft_rule "$chain" "meta l4proto { tcp, udp } $NFT_MARK_SET"
}

# Render the full ruleset. Lists are resolved into $2 (a work directory).
nft_render() {
	local file="$1" dir="$2" kind=""

	NFT_FILE="$file"
	NFT_MARK_SET="meta mark set meta mark | $NFT_INTERCEPT_MARK"
	: >"$NFT_FILE" || return 1
	for kind in dst src direct direct_src; do
		lists_resolve "$kind" "$dir/$kind.4" "$dir/$kind.6" || return 1
	done

	nft_render_base
	nft_fill_set proxy_dst "$dir/dst.4"
	nft_fill_set proxy_dst6 "$dir/dst.6"
	nft_fill_set proxy_src "$dir/src.4"
	nft_fill_set proxy_src6 "$dir/src.6"
	nft_fill_set direct_dst "$dir/direct.4"
	nft_fill_set direct_dst6 "$dir/direct.6"
	if [ "$POLICY_MODE" = "proxy-first" ] && [ "$DNS_MODE" != "fake-ip" ]; then
		nft_fill_set direct_src "$dir/direct_src.4"
		nft_fill_set direct_src6 "$dir/direct_src.6"
	fi

	# DNS hijack and NetBird ingress exclusion.
	nft_rule dns_hijack "iifname \"$NETBIRD_INTERFACE\" return"
	if [ "$DNS_HIJACK" = "1" ]; then
		nft_rule dns_hijack "iifname @source_ifaces ip daddr != @localv4 meta l4proto { tcp, udp } th dport 53 redirect to :$MIHOMO_DNS_PORT"
		nft_rule dns_hijack "iifname @source_ifaces ip6 daddr != @localv6 meta l4proto { tcp, udp } th dport 53 redirect to :$MIHOMO_DNS_PORT"
	fi

	# Client traffic.
	nft_rule mangle_prerouting "iifname \"$NETBIRD_INTERFACE\" return"
	nft_rule mangle_prerouting "iifname @source_ifaces jump prerouting_policy"
	nft_render_guards prerouting_policy
	[ "$DNS_HIJACK" = "1" ] && nft_rule prerouting_policy "meta l4proto { tcp, udp } th dport 53 return"
	if [ "$POLICY_MODE" = "proxy-first" ]; then
		nft_render_direct_returns prerouting_policy "$dir/direct.4" "$dir/direct.6"
		nft_render_direct_devices prerouting_policy "$dir/direct_src.4" "$dir/direct_src.6"
		nft_render_catch_all prerouting_policy
	else
		nft_render_list_marks prerouting_policy "$dir/dst.4" "$dir/dst.6" daddr proxy_dst
		nft_render_list_marks prerouting_policy "$dir/src.4" "$dir/src.6" saddr proxy_src
		nft_render_fakeip prerouting_policy
	fi

	# TPROXY marked packets (client traffic and rerouted router traffic).
	nft_rule proxy_redirect "iifname \"$NETBIRD_INTERFACE\" return"
	nft_rule proxy_redirect "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$MIHOMO_TPROXY_PORT"
	nft_rule proxy_redirect "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK meta nfproto ipv6 meta l4proto { tcp, udp } tproxy ip6 to [::1]:$MIHOMO_TPROXY_PORT"

	# Router-originated traffic. Mihomo's own sockets carry the routing mark.
	nft_rule mangle_output "meta mark $MIHOMO_ROUTING_MARK return"
	nft_rule mangle_output "meta l4proto { tcp, udp } th dport $MIHOMO_TPROXY_PORT return"
	nft_render_guards mangle_output
	nft_rule mangle_output "meta l4proto { tcp, udp } th dport 53 return"
	nft_rule mangle_output "ip daddr @bypass_dst return"
	nft_rule mangle_output "ip6 daddr @bypass_dst6 return"
	nft_rule mangle_output "meta mark & $ZAPRET_DESYNC_MARK == $ZAPRET_DESYNC_MARK return"
	nft_rule mangle_output "meta mark & $ZAPRET_DESYNC_MARK_POSTNAT == $ZAPRET_DESYNC_MARK_POSTNAT return"
	nft_render_netbird_output
	if [ "$POLICY_MODE" = "proxy-first" ]; then
		nft_render_direct_returns mangle_output "$dir/direct.4" "$dir/direct.6"
		nft_render_catch_all mangle_output
	else
		nft_render_list_marks mangle_output "$dir/dst.4" "$dir/dst.6" daddr proxy_dst
		nft_render_fakeip mangle_output
	fi
}

nft_apply() {
	local dir="$PKG_TMP_DIR/nft" rc=0

	ensure_dir "$dir" || return 1
	nft_render "$dir/ruleset.nft" "$dir" || rc=1
	if [ "$rc" -eq 0 ] && cmp -s "$dir/ruleset.nft" "$NFT_APPLIED_FILE" && nft_active; then
		rm -rf "$dir"
		return 0
	fi
	[ "$rc" -eq 0 ] && nft -f "$dir/ruleset.nft" || rc=1
	if [ "$rc" -ne 0 ]; then
		rm -f "$NFT_APPLIED_FILE"
		err "Failed to apply nftables policy (see $dir/ruleset.nft)"
		return 1
	fi
	mv -f "$dir/ruleset.nft" "$NFT_APPLIED_FILE" || rm -f "$NFT_APPLIED_FILE"
	rm -rf "$dir"
	return 0
}

nft_cleanup() {
	rm -f "$NFT_APPLIED_FILE"
	nft delete table inet "$NFT_TABLE_NAME" 2>/dev/null
	return 0
}

nft_active() {
	nft list table inet "$NFT_TABLE_NAME" >/dev/null 2>&1
}

# bypass_set <add|delete> <addresses...>: let the router reach these addresses
# directly. "add" uses a timeout so a killed download cannot leave them.
nft_bypass() {
	local action="$1" addr="" suffix=""
	shift

	[ "$action" = add ] && suffix=" timeout 2m"
	for addr in "$@"; do
		if is_ipv4 "$addr"; then
			nft "$action" element inet "$NFT_TABLE_NAME" bypass_dst "{ $addr$suffix }" 2>/dev/null
		elif is_ipv6 "$addr"; then
			nft "$action" element inet "$NFT_TABLE_NAME" bypass_dst6 "{ $addr$suffix }" 2>/dev/null
		fi
	done
	return 0
}
