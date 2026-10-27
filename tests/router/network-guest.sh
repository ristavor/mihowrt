#!/bin/ash
# Destructive fixtures ONLY for tests/router/start.sh's disposable QEMU guest.
set -eu
WORK=/tmp/mihowrt-network-test
PIDS=""
NAMESPACES=""
LINKS=""
SAVED=0
DEFAULTS=0
CURRENT=prerequisites

fatal() { echo "FAIL: $*" >&2; exit 1; }
absent() { if "$@"; then fatal "expected absence: $*"; fi; }
# Shell arithmetic is confined to normalized unsigned inputs.
. /usr/lib/mihowrt/constants.sh
. /usr/lib/mihowrt/helpers.sh
mihowrt_load_modules

record() {
	awk -F '\t' -v row="$1" '$1 != row' "$WORK/results.tsv" >"$WORK/results.new"
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$WORK/results.new"
	mv "$WORK/results.new" "$WORK/results.tsv"
}

snap() {
	local label="$1"
	uname -r >"$WORK/logs/$label.kernel"
	nft list ruleset >"$WORK/logs/$label.nft" 2>&1 || true
	ip -4 rule show >"$WORK/logs/$label.rules4"
	ip -6 rule show >"$WORK/logs/$label.rules6"
	ip -4 route show table all >"$WORK/logs/$label.routes4"
	ip -6 route show table all >"$WORK/logs/$label.routes6"
	ip -o addr show >"$WORK/logs/$label.addresses"
}

ready() {
	local i=""
	for i in $(seq 1 40); do
		/usr/bin/mihowrt status-json | jq -e '.running and .policy_active and .dns_ok' >/dev/null && return 0
		sleep 1
	done
	return 1
}

cleanup() {
	local rc=$? pid="" ns="" link="" conf="" restore=0
	# Restoration must finish even if the controlling SSH session goes away.
	trap '' INT TERM HUP PIPE
	trap - EXIT
	set +e
	if [ "$rc" -ne 0 ] && [ "$CURRENT" != prerequisites ] && ! grep -F "$CURRENT	FAIL" "$WORK/results.tsv" >/dev/null; then
		record "$CURRENT" FAIL "exit=$rc; logs/$CURRENT.log (stopped at first failure)"
	fi
	snap final
	for pid in $PIDS; do kill "$pid" 2>/dev/null; done
	for pid in $PIDS; do wait "$pid" 2>/dev/null; done
	if [ "$SAVED" = 1 ]; then
		/etc/init.d/mihowrt stop 6>&- 7>&- 8>&- 9>&- >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		# Restore the user's YAML through the same API used to install the fixture.
		if [ -f "$WORK/saved/config.yaml" ]; then
			cp "$WORK/saved/config.yaml" "$WORK/restore.upload"
			mv "$WORK/restore.upload" /tmp/mihowrt-config.network-restore
			/usr/bin/mihowrt save-config /tmp/mihowrt-config.network-restore >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		else
			rm -f /opt/clash/config.yaml
		fi
		if [ -f "$WORK/saved/config.yaml.bak" ]; then
			cp -p "$WORK/saved/config.yaml.bak" /opt/clash/config.yaml.bak || restore=1
		else
			rm -f /opt/clash/config.yaml.bak
		fi
		rm -rf /opt/clash/lst /etc/mihowrt/policy-cache
		[ ! -d "$WORK/saved/lst" ] || cp -a "$WORK/saved/lst" /opt/clash/lst
		[ ! -d "$WORK/saved/policy-cache" ] || cp -a "$WORK/saved/policy-cache" /etc/mihowrt/policy-cache
		for conf in mihowrt dhcp firewall network; do
			uci -q revert "$conf"
			cp -p "$WORK/saved/$conf" "/etc/config/$conf" || restore=1
		done
	fi
	if [ "$DEFAULTS" = 1 ]; then
		ip -4 route del default via 198.19.22.2 dev m22w metric 42422 || restore=1
		ip -6 route del default via 2001:db8:ffff::2 dev m22w metric 42422 || restore=1
	fi
	if [ -f "$WORK/occupied" ]; then
		ip -4 rule del priority 50 fwmark 0x220000/0xff0000 lookup 201 || restore=1
		ip -4 route del blackhole 198.19.222.0/24 table 200 || restore=1
	fi
	nft delete table inet m22_netbird 2>/dev/null
	ip -6 addr del 2001:db8:dead::1/128 dev m22w 2>/dev/null
	ip -6 route del unreachable 2001:db8:2200::/56 2>/dev/null
	ip -6 route del 2001:db8:2220::/64 dev m22p table 20222 2>/dev/null
	for ns in $NAMESPACES; do ip netns del "$ns" || restore=1; done
	for link in $LINKS; do
		if ip link show "$link" >/dev/null 2>&1; then ip link del "$link" || restore=1; fi
	done
	if [ "$SAVED" = 1 ]; then
		/etc/init.d/network reload >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/firewall reload >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/dnsmasq restart >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		/etc/init.d/odhcpd restart >>"$WORK/logs/cleanup.log" 2>&1 || restore=1
		[ "$(cat "$WORK/saved/odhcpd.running")" = 1 ] || /etc/init.d/odhcpd stop
		[ "$(cat "$WORK/saved/dnsmasq.running")" = 1 ] || /etc/init.d/dnsmasq stop
		if [ "$(cat "$WORK/saved/mihowrt.running")" = 1 ]; then
			/etc/init.d/mihowrt start 6>&- 7>&- 8>&- 9>&- >>"$WORK/logs/cleanup.log" 2>&1 && ready || restore=1
		fi
		for conf in mihowrt dhcp firewall network; do
			cmp -s "$WORK/saved/$conf" "/etc/config/$conf" || restore=1
		done
		if [ -f "$WORK/saved/config.yaml" ]; then cmp -s "$WORK/saved/config.yaml" /opt/clash/config.yaml || restore=1; fi
		if [ -f "$WORK/saved/config.yaml.bak" ]; then cmp -s "$WORK/saved/config.yaml.bak" /opt/clash/config.yaml.bak || restore=1; fi
	fi
	rm -f /tmp/mihowrt-config.network-restore /tmp/mihowrt-config.network-fixture
	for conf in dst src direct direct-src; do rm -f "/tmp/mihowrt-policy-list.network-$conf"; done
	if [ "$restore" = 0 ]; then echo PASS >"$WORK/cleanup.status"; else echo FAIL >"$WORK/cleanup.status"; rc=1; fi
	# Snapshots can contain credentials; retain only the evidence directory.
	[ "$restore" != 0 ] || rm -rf "$WORK/saved"
	rm -f "$WORK/guest.pid"
	exit "$rc"
}

# Standalone guest entry also acquires the owned directory; never reuse stale state.
[ "$(cat /sys/class/net/eth0/address)" = 52:54:00:12:34:01 ] || fatal 'not the designated disposable VM'
ubus call system board | grep -q QEMU || fatal 'not QEMU'
if [ ! -e "$WORK" ]; then
	mkdir -m 700 "$WORK"
	echo mihowrt-task-22 >"$WORK/.owner"
fi
[ ! -L "$WORK" ] && [ "$(cat "$WORK/.owner")" = mihowrt-task-22 ] || fatal 'refuse existing unowned work path'
mkdir "$WORK/logs" "$WORK/saved" || fatal 'refuse existing guest fixture state'
: >"$WORK/results.tsv"
for name in 'nft syntax' 'control reachable' 'client IPv6 rejected' 'local and IPv4 retained' \
	'core and other ingress retained' 'NetBird synthetic' 'routes and DNS boundaries' 'local names' 'fake-IP direct devices' lifecycle; do
	record "$name" 'NOT TESTED' 'not reached'
done
trap cleanup EXIT
trap 'exit 1' INT TERM HUP PIPE
echo $$ >"$WORK/guest.pid"

# Do not install prerequisites implicitly, and never turn missing tools into PASS.
for tool in ip nft tcpdump curl dnsmasq uhttpd odhcp6c odhcpd jq hexdump nc socat; do
	command -v "$tool" >/dev/null || fatal "prerequisite unavailable: $tool"
done
[ -x /opt/clash/bin/clash ] || fatal 'prerequisite unavailable: Mihomo core'
ip netns list >"$WORK/logs/namespaces.before"
for name in m22-c m22-p m22-w m22-u m22-d m22-n; do
	ip netns list | grep -q "^$name\b" && fatal "refuse existing namespace $name"
done
for name in m22c m22p m22w m22u m22d wt0 m22nb; do
	ip link show "$name" >/dev/null 2>&1 && fatal "refuse existing link $name"
done
nft list table inet m22_netbird >/dev/null 2>&1 && fatal 'refuse existing nft table m22_netbird'
[ ! -e /tmp/mihowrt-config.network-fixture ] && [ ! -L /tmp/mihowrt-config.network-fixture ] || fatal 'refuse existing upload'
[ ! -e /tmp/mihowrt-config.network-restore ] && [ ! -L /tmp/mihowrt-config.network-restore ] || fatal 'refuse existing restore upload'
for name in dst src direct direct-src; do
	[ ! -e "/tmp/mihowrt-policy-list.network-$name" ] && [ ! -L "/tmp/mihowrt-policy-list.network-$name" ] || fatal "refuse existing list upload $name"
done
for conf in mihowrt dhcp firewall network; do
	[ -z "$(uci changes "$conf")" ] || fatal "refuse uncommitted UCI $conf"
	cp -p "/etc/config/$conf" "$WORK/saved/$conf"
	uci -q show "$conf" | grep -q '^.*\.m22' && fatal "refuse existing UCI fixture names in $conf"
done
[ ! -f /opt/clash/config.yaml ] || cp -p /opt/clash/config.yaml "$WORK/saved/config.yaml"
[ ! -f /opt/clash/config.yaml.bak ] || cp -p /opt/clash/config.yaml.bak "$WORK/saved/config.yaml.bak"
for name in mihowrt dnsmasq odhcpd; do
	if /etc/init.d/"$name" running; then echo 1; else echo 0; fi >"$WORK/saved/$name.running"
done
[ ! -d /opt/clash/lst ] || cp -a /opt/clash/lst "$WORK/saved/lst"
[ ! -d /etc/mihowrt/policy-cache ] || cp -a /etc/mihowrt/policy-cache "$WORK/saved/policy-cache"
SAVED=1
snap before
/etc/init.d/mihowrt stop 6>&- 7>&- 8>&- 9>&-


# Every veth and address is in the VM. Namespace clients never see eth0/eth1.
make_link() {
	local suffix="$1" root="$2" v4="$3" v6="$4"
	ip netns add "m22-$suffix"
	NAMESPACES="$NAMESPACES m22-$suffix"
	ip link add "$root" type veth peer name eth0 netns "m22-$suffix"
	LINKS="$LINKS $root"
	ip link set "$root" up
	ip addr add "$v4.1/24" dev "$root"
	ip -6 addr add "$v6::1/64" dev "$root" nodad
	ip netns exec "m22-$suffix" ip link set lo up
	ip netns exec "m22-$suffix" ip link set eth0 up
	ip netns exec "m22-$suffix" ip addr add "$v4.2/24" dev eth0
	ip netns exec "m22-$suffix" ip -6 addr add "$v6::2/64" dev eth0 nodad
	ip netns exec "m22-$suffix" ip route add default via "$v4.1"
	ip netns exec "m22-$suffix" ip -6 route add default via "$v6::1"
}
make_link c m22c 192.0.2 fd22:10
make_link p m22p 192.0.3 fd22:20
make_link w m22w 198.19.22 2001:db8:ffff
make_link u m22u 192.0.4 2001:db8:30
make_link d m22d 192.0.5 2001:db8:40
make_link n wt0 192.0.6 2001:db8:50
ip netns exec m22-c ip link set eth0 address 02:00:00:22:00:02
ip -6 addr add 2001:db8:10::1/64 dev m22c nodad
ip netns exec m22-c ip -6 addr add 2001:db8:10::2/64 dev eth0 nodad
ip netns exec m22-c ip -6 route change default via fd22:10::1 src 2001:db8:10::2
# RA may add another default; pin only the synthetic WAN prefix's source.
ip netns exec m22-c ip -6 route add 2001:db8:ffff::/64 via fd22:10::1 dev eth0 src 2001:db8:10::2
ip -6 addr add 2001:db8:20::1/64 dev m22p nodad
ip netns exec m22-p ip -6 addr add 2001:db8:20::2/64 dev eth0 nodad
ip -6 addr add 2001:db8:dead::1/128 dev m22w nodad
ip -4 route add default via 198.19.22.2 dev m22w metric 42422
ip -6 route add default via 2001:db8:ffff::2 dev m22w metric 42422
DEFAULTS=1

# Test-only zones permit controls but explicitly deny client -> denied zone.
for name in c p w u d n; do
	case "$name" in n) iface=wt0 ;; *) iface="m22$name" ;; esac
	uci set "firewall.m22$name=zone"
	uci set "firewall.m22$name.name=m22$name"
	uci add_list "firewall.m22$name.device=$iface"
	uci set "firewall.m22$name.input=ACCEPT"
	uci set "firewall.m22$name.output=ACCEPT"
	uci set "firewall.m22$name.forward=REJECT"
done
for name in cw cp uw nw wc; do
	src="$(printf '%s' "$name" | cut -c1)"
	dst="$(printf '%s' "$name" | cut -c2)"
	uci set "firewall.m22$name=forwarding"
	uci set "firewall.m22$name.src=m22$src"
	uci set "firewall.m22$name.dest=m22$dst"
done
uci commit firewall
/etc/init.d/firewall reload
# Netifd/odhcpd fixture: no existing interface or DHCP section is changed here.
uci set network.m22c=interface
uci set network.m22c.proto=static
uci set network.m22c.device=m22c
uci set network.m22c.ipaddr=192.0.2.1
uci set network.m22c.netmask=255.255.255.0
uci add_list network.m22c.ip6addr=fd22:10::1/64
uci add_list network.m22c.ip6addr=2001:db8:10::1/64
uci set dhcp.m22c=dhcp
uci set dhcp.m22c.interface=m22c
uci set dhcp.m22c.ra=server
uci set dhcp.m22c.dhcpv6=server
uci add_list dhcp.m22c.ra_flags=managed-config
uci add_list dhcp.m22c.ra_flags=other-config
uci set 'dhcp.@dnsmasq[0].local=/corp22/'
uci set 'dhcp.@dnsmasq[0].domain=corp22'
uci set "dhcp.@dnsmasq[0].leasefile=$WORK/leases"
uci add_list 'dhcp.@dnsmasq[0].server=/conditional22.test/198.19.22.2'
uci add_list 'dhcp.@dnsmasq[0].server=/openwrt.org/10.0.2.3'
uci set dhcp.m22host=domain
uci set dhcp.m22host.name=m22host.lan
uci set dhcp.m22host.ip=192.0.2.10
uci set dhcp.m22static=domain
uci set dhcp.m22static.name=static22.corp22
uci set dhcp.m22static.ip=192.0.2.9
uci set dhcp.m22static6=domain
uci set dhcp.m22static6.name=static22.corp22
uci set dhcp.m22static6.ip=fd22:10::9
printf '0 02:00:00:22:00:02 192.0.2.2 lease22 *\n' >"$WORK/leases"
uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/odhcpd restart
uci show dhcp >"$WORK/logs/dhcp.fixture.before"

# Listener fixtures use only tracked foreground processes (no daemonized children).
mkdir "$WORK/www" "$WORK/node"
mkdir "$WORK/www/cgi-bin"
cat >"$WORK/www/cgi-bin/hold" <<'EOF'
#!/bin/ash
printf 'Content-Type: text/plain\r\n\r\nmihowrt-network-fixture\n'
sleep 8
EOF
chmod +x "$WORK/www/cgi-bin/hold"
printf 'mihowrt-network-fixture\n' >"$WORK/www/index.html"
for name in p w u d; do
	ip netns exec "m22-$name" uhttpd -f -p 0.0.0.0:8080 -p '[::]:8080' -p 0.0.0.0:8081 -h "$WORK/www" >"$WORK/logs/http-$name.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
	PIDS="$PIDS $!"
done
uhttpd -f -p 0.0.0.0:8088 -p '[::]:8088' -h "$WORK/www" >"$WORK/logs/http-router.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
ip netns exec m22-w dnsmasq --keep-in-foreground --conf-file=/dev/null --no-resolv --no-hosts \
	--bind-interfaces --interface=eth0 --log-queries --log-facility=- \
	--address=/raw22.test/198.19.22.2 --address=/raw22.test/2001:db8:ffff::2 \
	--address=/conditional22.test/198.19.22.2 --address=/primary22.example.net/198.19.22.22 \
	--address=/fake22.example.net/198.19.22.2 --address=/public22.example.org/198.19.22.2 >"$WORK/logs/dns-wan.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
cat >"$WORK/node/config.yaml" <<'EOF'
socks-port: 1080
allow-lan: true
bind-address: '*'
ipv6: true
mode: rule
log-level: debug
rules:
  - MATCH,DIRECT
EOF
ip netns exec m22-w /opt/clash/bin/clash -d "$WORK/node" -f "$WORK/node/config.yaml" >"$WORK/logs/node.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
tcpdump -ni m22w -U -w "$WORK/logs/wan.pcap" >"$WORK/logs/wan-capture.log" 2>&1 6>&- 7>&- 8>&- 9>&- &
PIDS="$PIDS $!"
sleep 3
for pid in $PIDS; do kill -0 "$pid" || fatal "fixture process exited: $pid"; done

# Install user YAML exclusively through the editor API. No provider-file edits.
profile() {
	local mode="$1" dns="$2" flag="$3" hijack="$4" filter=blacklist
	[ "$mode" != direct-first ] || filter=whitelist
	uci set "mihowrt.settings.dns_hijack=$hijack"
	uci set mihowrt.settings.disable_quic=0
	uci set mihowrt.settings.block_client_ipv6=0
	uci -q delete mihowrt.settings.provider_override || true
	uci -q delete mihowrt.settings.source_network_interfaces || true
	uci add_list mihowrt.settings.source_network_interfaces=m22c
	uci add_list mihowrt.settings.source_network_interfaces=wt0
	uci commit mihowrt
	cat > /tmp/mihowrt-config.network-fixture <<EOF
ipv6: true
mode: rule
log-level: debug
dns:
  enable: true
  ipv6: true
  enhanced-mode: $dns
  fake-ip-filter-mode: $filter
  fake-ip-filter: ['+.example.org']
  nameserver: [198.19.22.2]
  nameserver-policy:
    '+.primary22.example.net': 198.19.22.2
    '+.openwrt.org': 10.0.2.3
proxies:
  - name: NODE22
    type: socks5
    server: '2001:db8:ffff::2'
    port: 1080
    udp: true
rules:
  - DOMAIN,fake22.example.net,NODE22
  - DST-PORT,8081,NODE22
  - MATCH,DIRECT
x-mihowrt:
  block-client-ipv6: $flag
EOF
	/usr/bin/mihowrt save-config /tmp/mihowrt-config.network-fixture
	/usr/bin/mihowrt reload
	/usr/bin/mihowrt profile-json | jq -e --arg mode "$mode" ' .mode == $mode'
}

set_lists() {
	local selector="$1" kind=""
	for kind in dst src direct direct-src; do : >"/tmp/mihowrt-policy-list.network-$kind"; done
	case "$selector" in
	dst) printf '2001:db8:ffff::2\n' > /tmp/mihowrt-policy-list.network-dst ;;
	src) printf '2001:db8:10::2\nfd22:10::2\n' > /tmp/mihowrt-policy-list.network-src ;;
	mac) printf '02:00:00:22:00:02\n' > /tmp/mihowrt-policy-list.network-src ;;
	port) printf ';8080\n;53\n' > /tmp/mihowrt-policy-list.network-dst ;;
	core) printf ';8081\n' > /tmp/mihowrt-policy-list.network-dst ;;
	empty) ;;
	*) fatal "unknown list selector: $selector" ;;
	esac
	# Matching direct exceptions in blacklist/redir-host must not escape the ban.
	cp /tmp/mihowrt-policy-list.network-dst /tmp/mihowrt-policy-list.network-direct
	cp /tmp/mihowrt-policy-list.network-src /tmp/mihowrt-policy-list.network-direct-src
	/usr/bin/mihowrt apply-lists /tmp/mihowrt-policy-list.network-dst /tmp/mihowrt-policy-list.network-src /tmp/mihowrt-policy-list.network-direct /tmp/mihowrt-policy-list.network-direct-src
}

http() {
	local ns="$1" address="$2" port="${3:-8080}"
	ip netns exec "m22-$ns" curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 "http://$address:$port/"
}

# BusyBox nc has no UDP/timeout switches. nslookup supplies UDP; a tracked
# watchdog bounds it, while nc carries a length-prefixed DNS packet for TCP.
bounded() {
	local pid="" rc=0 i=""
	# An asynchronous command gets /dev/null as stdin unless it is redirected explicitly.
	if [ -n "${BOUNDED_STDIN:-}" ]; then
		"$@" <"$BOUNDED_STDIN" 6>&- 7>&- 8>&- 9>&- &
	else
		"$@" 6>&- 7>&- 8>&- 9>&- &
	fi
	pid=$!
	for i in $(seq 1 5); do
		kill -0 "$pid" 2>/dev/null || break
		sleep 1
	done
	kill "$pid" 2>/dev/null || true
	wait "$pid" || rc=$?
	return "$rc"
}

dns_udp() {
	local server="$1" name="$2" type="$3" expected="$4"
	bounded ip netns exec m22-c nslookup "-type=$type" "$name" "$server" >"$WORK/logs/dns-last.log" 2>&1
	cat "$WORK/logs/dns-last.log"
	# PTR replies have no Name: line; the answer is everything after the server header.
	awk 'answer; /^$/ {answer=1}' "$WORK/logs/dns-last.log" | grep -F "$expected"
}

dns_tcp() {
	local server="$1" name="$2" type="$3" expected="$4" label="" size="" hi="" lo="" oldifs="$IFS"
	# Build DNS query bytes without od/base64/Python; command substitution would strip NUL, so only fixed printf formats emit them.
	{
		printf '\022\064\001\000\000\001\000\000\000\000\000\000'
		IFS=.
		for label in $name; do printf '%b%s' "$(printf '\\%03o' "${#label}")" "$label"; done
		IFS="$oldifs"
		printf '\000'
		case "$type" in A) printf '\000\001' ;; AAAA) printf '\000\034' ;; PTR) printf '\000\014' ;; *) return 1 ;; esac
		printf '\000\001'
	} >"$WORK/query.bin"
	size="$(uint_norm "$(wc -c <"$WORK/query.bin")")"
	hi=$((size / 256)); lo=$((size % 256))
	# shellcheck disable=SC2059 # octal escapes for the fixed 2-byte TCP DNS length prefix
	{ printf "\\$(printf '%03o' "$hi")\\$(printf '%03o' "$lo")"; cat "$WORK/query.bin"; } >"$WORK/query.tcp"
	# nc can wait for EOF after a valid reply; the watchdog status is not the DNS oracle.
	BOUNDED_STDIN="$WORK/query.tcp" bounded ip netns exec m22-c nc "$server" 53 >"$WORK/reply.bin" || true
	hexdump -v -e '1/1 "%02x"' "$WORK/reply.bin" >"$WORK/logs/dns-tcp-last.hex"
	cat "$WORK/logs/dns-tcp-last.hex"
	# ID 0x1234, standard successful response, at least one answer and payload.
	grep -Eq '^....1234[89][0-9a-f]80' "$WORK/logs/dns-tcp-last.hex"
	grep -q "$expected" "$WORK/logs/dns-tcp-last.hex"
}

check_nft() {
	local mode="" dns="" flag="" hijack=""
	for pair in direct-first:fake-ip proxy-first:fake-ip proxy-first:redir-host; do
		mode="${pair%:*}"; dns="${pair#*:}"
		for flag in false true; do
			for hijack in 0 1; do
				profile "$mode" "$dns" "$flag" "$hijack"
				[ -s /tmp/mihowrt/nft.applied ]
				nft -c -f /tmp/mihowrt/nft.applied
				snap "syntax-$mode-$dns-$flag-$hijack"
				cp /tmp/mihowrt/nft.applied "$WORK/logs/syntax-$mode-$dns-$flag-$hijack.applied"
			done
		done
	done
}

check_control() {
	profile direct-first fake-ip false 0
	http c 198.19.22.2 | grep mihowrt-network-fixture
	http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	http c 192.0.3.2 | grep mihowrt-network-fixture
	http c '[fd22:20::2]' | grep mihowrt-network-fixture
	dns_udp 198.19.22.2 raw22.test A 198.19.22.2
	dns_udp 2001:db8:ffff::2 raw22.test AAAA 2001:db8:ffff::2
	profile direct-first fake-ip false 1
	# Unique fake-IP answer proves Mihomo DNS, not raw WAN DNS reachability.
	dns_udp 2001:db8:ffff::2 public22.example.org A 198.18.
	if awk '/^Name:/ {answer=1} answer' "$WORK/logs/dns-last.log" | grep -q '198.19.22.2'; then fatal 'raw DNS answer instead of Mihomo fake-IP'; fi
}

reject_fresh() {
	local label="$1" cap="$WORK/logs/reject-$1.pcap" pid="" wanpid="" start="" end="" rc=0
	# Independent capture for each fresh TCP and UDP/NTP flow.
	tcpdump -ni m22c -U -w "$cap" 'ip6 and (host 2001:db8:ffff::2 or icmp6)' >"$WORK/logs/reject-$label.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
	pid=$!
	tcpdump -ni m22w -U -w "$WORK/logs/reject-$label.wan.pcap" 'ip6 and dst host 2001:db8:ffff::2 and (tcp dst port 8080 or udp dst port 123)' >"$WORK/logs/reject-$label.wan-capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
	wanpid=$!
	trap 'kill "$pid" "$wanpid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; wait "$wanpid" 2>/dev/null || true' EXIT
	sleep 1
	nft list chain inet mihowrt client_ipv6_egress >"$WORK/logs/reject-$label.before"
	start="$(date +%s)"
	http c '[2001:db8:ffff::2]' >"$WORK/logs/reject-$label.http" 2>&1 || rc=$?
	end="$(date +%s)"
	printf 'TCP expected=refused (not timeout) actual_exit=%s elapsed_seconds=' "$rc"
	awk -v start="$start" -v end="$end" 'BEGIN {print end-start}'
	# Curl 7 = failed connect. Timeout 28 must never count as rejection.
	[ "$rc" = 7 ]
	printf 'unlisted-ntp-probe' >"$WORK/udp-probe"
	BOUNDED_STDIN="$WORK/udp-probe" bounded ip netns exec m22-c socat - 'UDP6-DATAGRAM:[2001:db8:ffff::2]:123' >"$WORK/logs/reject-$label.udp" 2>&1 || true
	sleep 1
	kill "$pid" "$wanpid"; wait "$pid" 2>/dev/null || true; wait "$wanpid" 2>/dev/null || true
	trap - EXIT
	tcpdump -nn -vv -r "$cap" >"$WORK/logs/reject-$label.decoded" 2>&1
	cat "$WORK/logs/reject-$label.decoded"
	grep -Eq 'Flags \[R\.?\]' "$WORK/logs/reject-$label.decoded"
	# Decode raw bytes too: ICMPv6 type=1/code=1, not a generic unreachable.
	tcpdump -nn -r "$cap" 'icmp6 and ip6[40] == 1 and ip6[41] == 1' >"$WORK/logs/reject-$label.admin" 2>&1
	grep -q 'unreachable' "$WORK/logs/reject-$label.admin"
	nft list chain inet mihowrt client_ipv6_egress >"$WORK/logs/reject-$label.after"
	awk '/counter packets/ {for(i=1;i<=NF;i++) if($i=="packets") print $(i+1)}' "$WORK/logs/reject-$label.before" >"$WORK/count.before"
	awk '/counter packets/ {for(i=1;i<=NF;i++) if($i=="packets") print $(i+1)}' "$WORK/logs/reject-$label.after" >"$WORK/count.after"
	awk 'NR==FNR {before[FNR]=$1; n=FNR; next} {if($1<=before[FNR]) bad=1; m=FNR} END {exit bad || n!=2 || m!=2}' "$WORK/count.before" "$WORK/count.after"
	# No WAN-bound connection or DNS query, even if a broken guard hid the client
	# behind Mihomo's router-originated socket. Capture is scoped to this flow.
	tcpdump -nn -r "$WORK/logs/reject-$label.wan.pcap" >"$WORK/logs/reject-$label.wan-decoded" 2>&1
	absent grep -q 'IP6 ' "$WORK/logs/reject-$label.wan-decoded"
	/usr/bin/mihowrt logs-json 500 >"$WORK/logs/reject-$label.core.json"

}

# Observe marked IPv6 immediately before delivery to the core. A successful
# request plus Mihomo's log and a positive counter prove the selected path.
selected_ipv6() {
	local label="$1"
	nft insert rule inet mihowrt proxy_redirect meta mark \& 0x08000000 == 0x08000000 ip6 daddr 2001:db8:ffff::2 tcp dport 8080 counter comment selected-ipv6
	http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	nft list chain inet mihowrt proxy_redirect >"$WORK/logs/selected-$label.nft"
	grep 'comment "selected-ipv6"' "$WORK/logs/selected-$label.nft" | grep -Eq 'counter packets [1-9]'
	/usr/bin/mihowrt logs-json 500 >"$WORK/logs/selected-$label.core.json"
	grep -q '2001:db8:ffff::2.*8080' "$WORK/logs/selected-$label.core.json"
}

check_reject() {
	local pair="" hijack="" selector="" flag=""
	for hijack in 0 1; do
		profile direct-first fake-ip true "$hijack"
		set_lists empty
		(reject_fresh "direct-first-$hijack-unlisted")
		if [ "$hijack" = 1 ]; then
			dns_udp 2001:db8:ffff::2 public22.example.org A 198.18.
		fi
		for selector in dst src mac port; do
			set_lists "$selector"
			selected_ipv6 "$hijack-$selector"
		done
	done
	# Proxy-first's explicit exceptions are not banned by this flag. Compare
	# applied transactions as well as fresh successful external IPv6 requests.
	for pair in proxy-first:fake-ip proxy-first:redir-host; do
		for hijack in 0 1; do
			for flag in false true; do
				profile proxy-first "${pair#*:}" "$flag" "$hijack"
				set_lists dst
				absent nft list chain inet mihowrt client_ipv6_egress
				cp /tmp/mihowrt/nft.applied "$WORK/$flag.nft"
				http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
				if [ "$hijack" = 1 ]; then
					if [ "${pair#*:}" = fake-ip ]; then
						dns_udp 2001:db8:ffff::2 fake22.example.net A 198.18.
					else
						dns_udp 2001:db8:ffff::2 public22.example.org A 198.19.22.2
					fi
				fi
			done
			cmp -s "$WORK/false.nft" "$WORK/true.nft"
		done
	done
}

check_local() {
	local flag="" linklocal="" pid=""
	for flag in false true; do
		profile direct-first fake-ip "$flag" 1
		http c 198.19.22.2 | grep mihowrt-network-fixture
		http c '[fd22:20::2]' | grep mihowrt-network-fixture
		http c '[2001:db8:20::2]' | grep mihowrt-network-fixture
		linklocal="$(ip -6 -o addr show dev m22p scope link | awk '{split($4,a,"/");print a[1];exit}')"
		ip netns exec m22-p ping -6 -c 1 -W 2 "$linklocal%eth0"
		ip netns exec m22-c ping -6 -c 1 -W 2 fd22:10::1
		# The fw4 denied zone stays denied even though its prefix is localv6.
		if http c '[2001:db8:40::2]'; then fatal "fw4 denied inter-zone path opened ($flag)"; fi
		dns_udp fd22:10::1 static22.corp22 A 192.0.2.9
		dns_udp fd22:10::1 static22.corp22 AAAA fd22:10::9
		dns_udp fd22:10::1 9.2.0.192.in-addr.arpa PTR static22
		dns_udp fd22:10::1 lease22.corp22 A 192.0.2.2
		dns_tcp fd22:10::1 static22.corp22 A c0000209
		dns_tcp fd22:10::1 static22.corp22 AAAA fd220010000000000000000000000009
		dns_tcp fd22:10::1 9.2.0.192.in-addr.arpa PTR 7374617469633232
		# odhcp6c actively solicits RA/DHCPv6 on the selected client link.
		tcpdump -ni m22c -U -w "$WORK/logs/local-$flag.pcap" 'icmp6 or udp port 546 or udp port 547' >"$WORK/logs/local-$flag.capture" 2>&1 6>&- 7>&- 8>&- 9>&- &
		pid=$!
		trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
		# tcpdump needs a moment to open the capture; a ping sent earlier is invisible to it.
		sleep 2
		# Earlier pings cached both neighbours; clear both caches so ND is a fresh on-wire exchange.
		ip netns exec m22-c ip -6 neigh flush dev eth0
		ip -6 neigh flush dev m22c
		ip netns exec m22-c ip -6 neigh show dev eth0 >"$WORK/logs/neigh-$flag.flushed"
		ip netns exec m22-c ping -6 -c 1 -W 2 fd22:10::1
		bounded ip netns exec m22-c odhcp6c -s /bin/true -N try eth0 >"$WORK/logs/dhcpv6-$flag.log" 2>&1 || true
		sleep 1
		kill "$pid"; wait "$pid" 2>/dev/null || true
		trap - EXIT
		tcpdump -nn -vv -r "$WORK/logs/local-$flag.pcap" >"$WORK/logs/local-$flag.decoded" 2>&1
		grep -q 'router advertisement' "$WORK/logs/local-$flag.decoded"
		grep -Eq 'dhcp6 (advertise|reply)' "$WORK/logs/local-$flag.decoded"
		grep -q 'neighbor solicitation' "$WORK/logs/local-$flag.decoded"
		grep -q 'neighbor advertisement' "$WORK/logs/local-$flag.decoded"
	done
}

check_core() {
	local pid=""
	profile direct-first fake-ip true 0
	# Port-only proxy selection catches IPv4 while IPv6 to the node is core output.
	set_lists core
	pid="$(cat /var/run/mihowrt/mihomo.pid)"
	http c 198.19.22.2 8081 | grep mihowrt-network-fixture
	# Earlier DNS controls may give the core a reverse mapping for this IP.
	grep -Eq -- '--> [^ ]+:8081 match .*using DIRECT' "$WORK/logs/node.log"
	# Packet evidence proves an actual IPv6 connection to the SOCKS5 node.
	sleep 1
	tcpdump -nn -r "$WORK/logs/wan.pcap" 'ip6 and dst host 2001:db8:ffff::2 and dst port 1080' >"$WORK/logs/core-node-ipv6.log" 2>&1
	grep -q 'Flags \[S\]' "$WORK/logs/core-node-ipv6.log"
	curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep mihowrt-network-fixture
	http u '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	[ "$pid" = "$(cat /var/run/mihowrt/mihomo.pid)" ]
}

netbird_rules() {
	local base="$1" port="$2" source="$3" mark="$4"
	nft delete table inet m22_netbird 2>/dev/null || true
	# Pre-policy producer and post-policy observer: conntrack marks must not be
	# confused with packet marks. Reply traffic is generated by the root HTTP server.
	nft -f - <<EOF
add table inet m22_netbird
add chain inet m22_netbird producer { type route hook output priority -151; policy accept; }
add chain inet m22_netbird observer { type route hook output priority -149; policy accept; }
add rule inet m22_netbird producer tcp dport $port meta mark 0 $source mark set $mark
add rule inet m22_netbird producer tcp sport 8088 meta mark set $base
add rule inet m22_netbird observer tcp dport $port meta mark & 0x08000000 == 0x08000000 counter comment "intercepted"
add rule inet m22_netbird observer tcp dport $port meta mark & 0x08000000 == 0 counter comment "direct"
add rule inet m22_netbird observer tcp sport 8088 ct direction reply meta mark $base counter comment "reply-direct"
EOF
}

check_netbird() {
	local pair="" iface="" base="" proxy="" path="" mark="" expected="" phase="" ns="m22-n"
	for pair in wt0:0x1bd00 m22nb:0x2bd00; do
		iface="${pair%:*}"; base="${pair#*:}"
		if [ "$iface" = m22nb ]; then
			ip link set wt0 name m22nb
			uci -q delete firewall.m22n.device
			uci add_list firewall.m22n.device=m22nb
			uci commit firewall
			/etc/init.d/firewall reload
		fi
		uci set "mihowrt.settings.netbird_interface=$iface"
		uci set "mihowrt.settings.netbird_mark=$base"
		for proxy in 0 1; do
			profile proxy-first redir-host true 0
			uci add_list "mihowrt.settings.source_network_interfaces=$iface"
			uci set "mihowrt.settings.netbird_proxy=$proxy"
			uci commit mihowrt
			for phase in producer-first service-first reconnect fw4-reload; do
				case "$phase" in
				producer-first)
					/etc/init.d/mihowrt stop 6>&- 7>&- 8>&- 9>&-
					netbird_rules "$base" 8080 meta "$base"
					/etc/init.d/mihowrt start 6>&- 7>&- 8>&- 9>&-; ready ;;
				service-first) nft delete table inet m22_netbird; /usr/bin/mihowrt reload ;;
				reconnect)
					ip link set "$iface" down; ip link set "$iface" up
					# Linux drops IPv6 addresses on admin-down; record that, then reconfigure like a reconnecting tunnel.
					ip -6 addr show dev "$iface" >"$WORK/logs/nb-$iface-$proxy-reconnect.addr6-after-up"
					ip -6 addr replace 2001:db8:50::1/64 dev "$iface" nodad
					/usr/bin/mihowrt net-refresh ;;
				fw4-reload) /etc/init.d/firewall reload; /usr/bin/mihowrt net-refresh ;;
				esac
				# Selected NetBird ingress remains direct despite the client ban.
				ip netns exec "$ns" curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep mihowrt-network-fixture
				for path in meta ct; do
					for offset in 0 16 17 32 33 34; do
						base_dec="$(uint_norm "$(printf '%d' "$base")")"
						offset="$(uint_norm "$offset")"
						mark="$(printf '0x%x' "$((base_dec | offset))")"
						netbird_rules "$base" 8080 "$path" "$mark"
						curl --noproxy '*' -g -fsS --connect-timeout 5 --max-time 5 'http://[2001:db8:ffff::2]:8080/' | grep mihowrt-network-fixture
						expected=direct
						if [ "$path" = ct ] || { [ "$proxy" = 1 ] && [ "$offset" = 0 ]; }; then expected=intercepted; fi
						nft list table inet m22_netbird >"$WORK/logs/nb-$iface-$proxy-$phase-$path-$offset.nft"
						grep "comment \"$expected\"" "$WORK/logs/nb-$iface-$proxy-$phase-$path-$offset.nft" | grep -Eq 'counter packets [1-9][0-9]*'
					done
				done
				netbird_rules "$base" 8080 meta "$base"
				http w 198.19.22.1 8088 | grep mihowrt-network-fixture
				nft list table inet m22_netbird | grep 'comment "reply-direct"' | grep -Eq 'counter packets [1-9][0-9]*'
			done
		done
		if [ "$iface" = m22nb ]; then
			ip link set m22nb name wt0
			uci -q delete firewall.m22n.device
			uci add_list firewall.m22n.device=wt0
			uci commit firewall
			/etc/init.d/firewall reload
		fi
	done
	nft delete table inet m22_netbird
	uci set mihowrt.settings.netbird_interface=wt0
	uci set mihowrt.settings.netbird_mark=0x1bd00
	uci set mihowrt.settings.netbird_proxy=0
	uci commit mihowrt
}

has_local6() { nft get element inet mihowrt localv6 "{ $1 }"; }

check_routes_dns() {
	local table="" priority=""
	/etc/init.d/mihowrt stop 6>&- 7>&- 8>&- 9>&-
	# Refuse occupied fixture slots instead of replacing anything already present.
	if ip -4 route show table all | grep -Eq ' table (200|201)( |$)'; then fatal 'refuse occupied route fixture slot'; fi
	if ip -4 rule show | grep -Eq '(^50:| lookup (200|201)( |$))'; then fatal 'refuse occupied rule fixture slot'; fi
	if ip -6 rule show | grep -Eq '(^50:| lookup (200|201)( |$))'; then fatal 'refuse occupied IPv6 rule fixture slot'; fi
	ip -4 route add blackhole 198.19.222.0/24 table 200
	ip -4 rule add priority 50 fwmark 0x220000/0xff0000 lookup 201
	: >"$WORK/occupied"
	profile direct-first fake-ip true 1
	/etc/init.d/mihowrt start 6>&- 7>&- 8>&- 9>&-; ready
	table="$(sed -n 's/^TABLE=//p' /var/run/mihowrt/route.state)"
	priority="$(sed -n 's/^PRIORITY=//p' /var/run/mihowrt/route.state)"
	[ "$table" != 200 ] && [ "$table" != 201 ] && [ "$priority" != 50 ]
	ip -4 route show table 200 | grep 'blackhole 198.19.222.0/24'
	ip -4 rule show | grep '^50:.*0x220000/0xff0000.*lookup 201'
	has_local6 2001:db8:10::2
	has_local6 2001:db8:20::2
	has_local6 2001:db8:30::2
	absent has_local6 2001:db8:ffff::2
	ip -6 route add unreachable 2001:db8:2200::/56
	ip -6 route add 2001:db8:2210::/64 via fd22:20::2 dev m22p
	ip -6 route add 2001:db8:2220::/64 dev m22p table 20222
	/usr/bin/mihowrt net-refresh
	has_local6 2001:db8:2200::1
	absent has_local6 2001:db8:2210::1
	absent has_local6 2001:db8:2220::1
	ip -6 route del unreachable 2001:db8:2200::/56
	ip -6 route del 2001:db8:2210::/64 via fd22:20::2 dev m22p
	ip -6 route del 2001:db8:2220::/64 dev m22p table 20222
	ip -6 addr del 2001:db8:30::1/64 dev m22u
	/usr/bin/mihowrt net-refresh
	absent has_local6 2001:db8:2200::1
	absent has_local6 2001:db8:30::2
	ip -6 addr add 2001:db8:30::1/64 dev m22u nodad
	# No-default semantics (D7): the former WAN connected prefix becomes local.
	ip -6 route del default via 2001:db8:ffff::2 dev m22w metric 42422
	/usr/bin/mihowrt net-refresh
	has_local6 2001:db8:ffff::2
	ip -6 route add default via 2001:db8:ffff::2 dev m22w metric 42422
	/usr/bin/mihowrt net-refresh
	absent has_local6 2001:db8:ffff::2
	absent has_local6 2001:db8:dead::1
	dns_udp 2001:db8:dead::1 static22.corp22 A 192.0.2.9
	dns_udp 2001:db8:dead::1 static22.corp22 AAAA fd22:10::9
	dns_tcp 2001:db8:dead::1 static22.corp22 A c0000209
	dns_udp 2001:db8:dead::1 conditional22.test A 198.19.22.2
	grep -q 'conditional22.test' "$WORK/logs/dns-wan.log"
	# Restart dnsmasq to clear its cache; an uncached real public DNS control.
	/etc/init.d/dnsmasq restart
	dns_udp 2001:db8:dead::1 openwrt.org A 'Address:'
	uci show dhcp >"$WORK/logs/dhcp.fixture.after"
	cmp "$WORK/logs/dhcp.fixture.before" "$WORK/logs/dhcp.fixture.after"
	# Both local and unique upstream answers must complete within the bounded probe.
	# Not .test: OpenWrt rfc6761.conf answers that TLD locally and never forwards it.
	if ! dns_udp fd22:10::1 primary22.example.net A 198.19.22.22; then
		/usr/bin/mihowrt logs-json 300 >"$WORK/logs/routes-core.json" 2>&1 || true
		cat /var/etc/dnsmasq.conf.* /tmp/dnsmasq.*.d/* >"$WORK/logs/dnsmasq-effective.conf" 2>&1 || true
		logread -e dnsmasq >"$WORK/logs/dnsmasq-syslog.log" 2>&1 || true
		return 1
	fi
}

check_local_names() {
	local pair="" router="" router_hex=""
	router="$(uci -q get system.@system[0].hostname)"
	[ -n "$router" ]
	router_hex="$(printf '%s' "$router" | hexdump -v -e '1/1 "%02x"')"
	for pair in direct-first:fake-ip proxy-first:fake-ip proxy-first:redir-host; do
		profile "${pair%:*}" "${pair#*:}" false 1
		set_lists empty
		dns_udp 192.0.2.1 m22host.lan A 192.0.2.10
		absent grep -q '198[.]18[.]' "$WORK/logs/dns-last.log"
		dns_tcp 192.0.2.1 m22host.lan A c000020a
		dns_udp 192.0.2.1 "$router.corp22" A 192.0.2.1
		absent grep -q '198[.]18[.]' "$WORK/logs/dns-last.log"
		dns_tcp 192.0.2.1 "$router.corp22" A c0000201
		dns_udp 192.0.2.1 10.2.0.192.in-addr.arpa PTR m22host.lan
		dns_tcp 192.0.2.1 10.2.0.192.in-addr.arpa PTR 6d3232686f7374036c616e
		dns_udp 192.0.2.1 1.2.0.192.in-addr.arpa PTR "$router"
		dns_tcp 192.0.2.1 1.2.0.192.in-addr.arpa PTR "$router_hex"
	done
}

check_fakeip_direct() {
	local address="" direct_pid="" proxy_pid="" i="" found=0
	profile proxy-first fake-ip true 1
	set_lists empty
	uci add_list mihowrt.settings.source_network_interfaces=m22u
	uci commit mihowrt
	/usr/bin/mihowrt reload
	cp /tmp/mihowrt/config.yaml "$WORK/runtime-before-device-list"
	printf '02:00:00:22:00:02\n' >/tmp/mihowrt-policy-list.network-direct-src
	/usr/bin/mihowrt apply-lists - - - /tmp/mihowrt-policy-list.network-direct-src
	cmp -s /tmp/mihowrt/config.yaml "$WORK/runtime-before-device-list"
	dns_udp 192.0.2.1 fake22.example.net A 198.18.
	address="$(awk '/^Name:/ {answer=1} answer && /^Address/ {for(i=1;i<=NF;i++) if($i ~ /^198[.]18[.]/) {print $i;exit}}' "$WORK/logs/dns-last.log")"
	[ -n "$address" ]
	ip netns exec m22-c curl --noproxy '*' -fsS --max-time 20 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/hold >"$WORK/logs/fake-direct.http" 2>&1 6>&- 7>&- 8>&- 9>&- &
	direct_pid=$!; PIDS="$PIDS $direct_pid"
	ip netns exec m22-u curl --noproxy '*' -fsS --max-time 20 --resolve "fake22.example.net:8080:$address" http://fake22.example.net:8080/cgi-bin/hold >"$WORK/logs/fake-proxy.http" 2>&1 6>&- 7>&- 8>&- 9>&- &
	proxy_pid=$!; PIDS="$PIDS $proxy_pid"
	for i in $(seq 1 7); do
		api_request GET /connections >"$WORK/logs/fake-connections.json"
		if jq -e --arg direct_port "$MIHOMO_DIRECT_TPROXY_PORT" --arg normal_port "$MIHOMO_TPROXY_PORT" '
			any(.connections[]; .metadata.sourceIP == "192.0.2.2"
				and .metadata.host == "fake22.example.net"
				and .metadata.inboundName == "mihowrt-direct" and .metadata.inboundPort == $direct_port
				and .rule == "InName" and .rulePayload == "mihowrt-direct"
				and .chains == ["DIRECT"])
			and any(.connections[]; .metadata.sourceIP == "192.0.4.2"
				and .metadata.host == "fake22.example.net"
				and .metadata.inboundName != "mihowrt-direct" and .metadata.inboundPort == $normal_port
				and .rule == "Domain" and (.chains | index("NODE22")) != null)
		' "$WORK/logs/fake-connections.json"; then found=1; break; fi
		sleep 1
	done
	[ "$found" = 1 ]
	wait "$direct_pid"; wait "$proxy_pid"
	PIDS="${PIDS% "$direct_pid" "$proxy_pid"}"
	grep -q mihowrt-network-fixture "$WORK/logs/fake-direct.http"
	grep -q mihowrt-network-fixture "$WORK/logs/fake-proxy.http"
	# Real IPv4 and IPv6 stay outside the core, even with the IPv6 flag on.
	http c 198.19.22.2 | grep mihowrt-network-fixture
	http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	snap fake-direct
}

check_lifecycle() {
	local pid="" old="" i="" opened=0
	profile direct-first fake-ip true 0
	set_lists empty
	pid="$(cat /var/run/mihowrt/mihomo.pid)"
	nft list chain inet mihowrt client_ipv6_egress
	uci set mihowrt.settings.block_client_ipv6=0
	uci add_list mihowrt.settings.provider_override=block_client_ipv6
	uci commit mihowrt
	/usr/bin/mihowrt reload
	absent nft list chain inet mihowrt client_ipv6_egress
	[ "$pid" = "$(cat /var/run/mihowrt/mihomo.pid)" ]
	/usr/bin/mihowrt reload
	[ "$pid" = "$(cat /var/run/mihowrt/mihomo.pid)" ]
	# Key removal/re-add uses fresh API uploads, preserving own-value override.
	/usr/bin/mihowrt read-config | jq -r .content | sed '/  block-client-ipv6:/d' > /tmp/mihowrt-config.network-fixture
	/usr/bin/mihowrt save-config /tmp/mihowrt-config.network-fixture
	absent nft list chain inet mihowrt client_ipv6_egress
	/usr/bin/mihowrt read-config | jq -r .content | sed '/^x-mihowrt:/a\  block-client-ipv6: true' > /tmp/mihowrt-config.network-fixture
	/usr/bin/mihowrt save-config /tmp/mihowrt-config.network-fixture
	absent nft list chain inet mihowrt client_ipv6_egress
	uci -q delete mihowrt.settings.provider_override
	uci commit mihowrt
	/usr/bin/mihowrt reload
	[ "$pid" = "$(cat /var/run/mihowrt/mihomo.pid)" ]
	nft list chain inet mihowrt client_ipv6_egress
	# Real failed kernel transaction through nft_apply, with a fixture-only fault.
	(
		settings_load
		BLOCK_CLIENT_IPV6=0
		# shellcheck disable=SC2329 # nft_apply calls the scoped fault injector
		nft() {
			if [ "$1" = -f ]; then printf '\nthis is an intentionally invalid fixture transaction\n' >>"$2"; fi
			/usr/sbin/nft "$@"
		}
		if nft_apply; then exit 1; fi
	)
	nft list chain inet mihowrt client_ipv6_egress
	(reject_fresh failed-transaction)
	/usr/bin/mihowrt reload
	/etc/init.d/mihowrt stop 6>&- 7>&- 8>&- 9>&-
	absent nft list table inet mihowrt
	http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	/etc/init.d/mihowrt start 6>&- 7>&- 8>&- 9>&-; ready
	(reject_fresh restart)
	old="$(cat /var/run/mihowrt/mihomo.pid)"
	kill -STOP "$old"
	for i in $(seq 1 100); do
		if ! nft list table inet mihowrt >/dev/null 2>&1; then opened=1; break; fi
		sleep 1
	done
	[ "$opened" = 1 ]
	http c '[2001:db8:ffff::2]' | grep mihowrt-network-fixture
	ready
	[ "$old" != "$(cat /var/run/mihowrt/mihomo.pid)" ]
	(reject_fresh watchdog-restart)
}

row() {
	local name="$1" expected="$2" fn="$3" rc=0
	# Development-only row filter; the host entry never sets it, and a filtered run cannot be exit 0.
	case ",${NETWORK_ROWS:-all}," in *,all,*|*",$name,"*) ;; *) return 0 ;; esac
	CURRENT="$name"
	printf '\n==> %s: expected %s\n' "$name" "$expected"
	# A separate, non-conditional subshell keeps ash errexit effective in checks.
	set +e
	(set -e; set -x; "$fn") >"$WORK/logs/$name.log" 2>&1
	rc=$?
	set -e
	cat "$WORK/logs/$name.log"
	if [ "$rc" != 0 ]; then
		record "$name" FAIL "expected=$expected; actual=failed; exit=$rc; logs/$name.log"
		exit 1
	fi
	record "$name" PASS "expected=$expected; actual=matched; exit=0; logs/$name.log"
	snap "$name"
}

profile direct-first fake-ip false 0
set_lists empty
/etc/init.d/mihowrt start 6>&- 7>&- 8>&- 9>&-
ready
row 'nft syntax' '12 live kernel syntax checks' check_nft
row 'control reachable' 'dual-stack raw controls and separate Mihomo DNS path' check_control
row 'client IPv6 rejected' 'direct-first unlisted REJECT, selected IPv6 TPROXY, IPv6 DNS redirected; proxy-first flag unchanged' check_reject
row 'local and IPv4 retained' 'IPv4, local DNS UDP/TCP, local IPv6, ND/RA/DHCPv6 and fw4 denial unchanged' check_local
row 'core and other ingress retained' 'IPv4 via IPv6 SOCKS5 node, router output and unselected ingress succeed' check_core
row 'NetBird synthetic' '2 interfaces/bases, 2 proxy settings, packet/ct original/reply paths, start orders/reconnect/fw4' check_netbird
row 'routes and DNS boundaries' 'occupied slots preserved, live prefix updates and DNS ownership/conditional boundaries' check_routes_dns
row 'local names' 'fixture host and router names resolve to LAN addresses over UDP/TCP, with local reverse answers in fake-ip/redir-host' check_local_names
row 'fake-IP direct devices' 'listed MAC fake-IP uses mihowrt-direct/DIRECT; unlisted device uses NODE22; real addresses bypass' check_fakeip_direct
row lifecycle 'provider/override, no-op, failed transaction, stop/watchdog/restart fresh flows' check_lifecycle
CURRENT=complete
