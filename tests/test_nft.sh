#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh nft.sh route.sh
assert_eq '/usr/share/nftables.d/chain-pre/input/30-mihowrt.nft' "$FW4_INPUT_INCLUDE" 'fw4 include path constant'
setup_runtime_paths "$tmpdir"

assert_eq "$tmpdir/proc" "${ROUTE_PROC_ROOT:-}" 'runtime paths isolate route proc checks'
assert_true 'fixture IPv6 is enabled' route_ipv6_enabled
for scope in all lo; do
 assert_file_contains "$ROUTE_PROC_ROOT/sys/net/ipv6/conf/$scope/disable_ipv6" 0 "fixture enables $scope IPv6"
done
pass 'runtime paths provide host-independent IPv6 state'

(
 nft() { printf '%s\n' "$*" >"$tmpdir/active.calls"; }
 nft_active
 assert_eq '-t list table inet mihowrt' "$(cat "$tmpdir/active.calls")" 'nft_active skips set elements'
)
pass 'nft active check omits set elements'

(
 content='first transaction'
 nft_input_hash() { printf '%s\n' "$content" | busybox sha256sum; }
 nft_render() { printf '%s\n' "$content" >"$1"; }
 nft_active() { return 0; }
 nft() { printf '%s\n' "$*" >>"$tmpdir/hash.calls"; }
 expected_hash() { printf '%s\n' "$content" | busybox sha256sum | cut -d ' ' -f1; }
 nft_apply
 assert_eq "$(expected_hash)" "$(cat "$NFT_APPLIED_FILE")" 'applied cache stores only SHA-256'
 printf stale >"$NET_FP_FILE"
 nft_apply
 assert_eq 1 "$(wc -l <"$tmpdir/hash.calls" | tr -d ' ')" 'identical hash skips apply'
 assert_false 'hash skip invalidates network fingerprint' test -e "$NET_FP_FILE"
 content='changed transaction'
 nft_apply
 assert_eq 2 "$(wc -l <"$tmpdir/hash.calls" | tr -d ' ')" 'changed hash applies'
 assert_eq "$(expected_hash)" "$(cat "$NFT_APPLIED_FILE")" 'changed hash replaces cache'
 printf '%s\n' "$content" >"$NFT_APPLIED_FILE"
 nft_apply
 assert_eq 3 "$(wc -l <"$tmpdir/hash.calls" | tr -d ' ')" 'legacy text cache applies once'
 assert_eq "$(expected_hash)" "$(cat "$NFT_APPLIED_FILE")" 'legacy text cache upgraded to hash'
 nft_apply
 assert_eq 3 "$(wc -l <"$tmpdir/hash.calls" | tr -d ' ')" 'upgraded cache skips identical apply'
)
pass 'applied ruleset hash skips identical and upgrades legacy cache'

# Plain entries predicate must not treat scoped addresses as set members.
(
 file="$tmpdir/plain.txt"
 assert_false 'missing list has no plain entries' nft_has_plain_entries "$file"
 : >"$file"
 assert_false 'empty list has no plain entries' nft_has_plain_entries "$file"
 printf '1.1.1.1;443\n;53\n' >"$file"
 assert_false 'port-only list has no plain entries' nft_has_plain_entries "$file"
 printf '2001:db8::1\n' >>"$file"
 assert_true 'mixed list has plain entries' nft_has_plain_entries "$file"
 printf '1.1.1.1\n' >"$file"
 assert_true 'plain list has entries' nft_has_plain_entries "$file"
 pass 'plain-entry predicate handles missing, empty, scoped and mixed lists'
)

# Port rules group exact specs in first-appearance order, with bounded chunks.
(
 NFT_FILE="$tmpdir/port-rules.nft"
 ports_file="$tmpdir/ports.txt"
 awk 'BEGIN { for (i = 0; i < 1200; i++) print "10.0." i ".0/24;443" }' >"$ports_file"
 : >"$NFT_FILE"
 nft_port_rules prerouting_policy "$ports_file" ip daddr accept
 assert_eq 3 "$(wc -l <"$NFT_FILE" | tr -d ' ')" 'grouped rule count'
 assert_eq 3 "$(grep -Fc 'th dport { 443 } accept' "$NFT_FILE")" 'all chunks retain the port spec and action'
 assert_eq $'512\n512\n176' "$(awk -F '[{}]' '{ print split($2, addresses, ",") }' "$NFT_FILE")" '512-address chunks'
 awk -F '[{}]' '{ gsub(/ /, "", $2); n = split($2, addresses, ","); for (i = 1; i <= n; i++) print addresses[i] ";443" }' "$NFT_FILE" >"$tmpdir/chunk-addresses.txt"
 assert_eq "$(cat "$ports_file")" "$(cat "$tmpdir/chunk-addresses.txt")" 'chunks preserve every address in order'
 pass 'grouped rule count'

 printf '1.1.1.1;443\n2.2.2.2;80,443\n3.3.3.3;443\n;53\n' >"$ports_file"
 : >"$NFT_FILE"
 nft_port_rules prerouting_policy "$ports_file" ip daddr accept
 expected='add rule inet mihowrt prerouting_policy ip daddr { 1.1.1.1, 3.3.3.3 } meta l4proto { tcp, udp } th dport { 443 } accept
add rule inet mihowrt prerouting_policy ip daddr { 2.2.2.2 } meta l4proto { tcp, udp } th dport { 80,443 } accept
add rule inet mihowrt prerouting_policy meta nfproto ipv4 meta l4proto { tcp, udp } th dport { 53 } accept'
 assert_eq "$expected" "$(cat "$NFT_FILE")" 'grouped semantics and first-spec order'
 pass 'grouped semantics'

 printf '2001:db8::1;400-500\n;53\n2001:db8::2;400-500\n;53\nplain-address\n;400-500\n;400-500\n' >"$ports_file"
 : >"$NFT_FILE"
 nft_port_rules mangle_output "$ports_file" ip6 saddr return
 expected='add rule inet mihowrt mangle_output ip6 saddr { 2001:db8::1, 2001:db8::2 } meta l4proto { tcp, udp } th dport { 400-500 } return
add rule inet mihowrt mangle_output meta nfproto ipv6 meta l4proto { tcp, udp } th dport { 400-500 } return
add rule inet mihowrt mangle_output meta nfproto ipv6 meta l4proto { tcp, udp } th dport { 53 } return'
 assert_eq "$expected" "$(cat "$NFT_FILE")" 'IPv6 source groups and one wildcard per spec'
 : >"$ports_file"
 : >"$NFT_FILE"
 nft_port_rules prerouting_policy "$ports_file" ip daddr accept
 printf '1.1.1.1\n' >"$ports_file"
 nft_port_rules prerouting_policy "$ports_file" ip daddr accept
 assert_eq '' "$(cat "$NFT_FILE")" 'empty and unscoped lists emit no port rules'
 pass 'grouped IPv6 source, wildcard and range rules'
)

# Real OpenWrt route formats, including delegated unreachable aggregates.
cat >"$tmpdir/routes.6" <<'ROUTES'
default via fe80::1 dev eth1
2a00:1::/64 dev eth1 proto kernel
unreachable 2001:db8:1::/48 dev lo
2001:db8:1:10::/64 dev br-lan
2001:db8:1:20::/64 dev br-guest
2000::/3 dev wg0
ROUTES
cat >"$tmpdir/routes.4" <<'ROUTES'
default via 10.0.2.2 dev eth1
10.0.2.0/24 dev eth1
203.0.113.0/24 dev br-dmz
0.0.0.0/1 dev wg0
5.0.0.0/8 dev wg1
ROUTES
ip() {
 case "$*" in
 '-4 route show table main') cat "$tmpdir/routes.4" ;;
 '-6 route show table main') cat "$tmpdir/routes.6" ;;
 '-4 route show default') grep '^default' "$tmpdir/routes.4" || true ;;
 '-6 route show default') grep '^default' "$tmpdir/routes.6" || true ;;
 *) fail "unexpected ip arguments: $*" ;;
 esac
}
assert_eq $'2001:db8:1::/48\n2001:db8:1:10::/64\n2001:db8:1:20::/64' "$(nft_connected_prefixes 6)" 'connected v6'
pass 'connected v6'
assert_eq '203.0.113.0/24' "$(nft_connected_prefixes 4)" 'connected v4'
pass 'connected v4'
(
 cat >>"$tmpdir/routes.6" <<'ROUTES'
default from 2001:db8::/48 via fe80::2 dev pppoe-wan proto static metric 512 pref medium
2a00:2::/64 dev pppoe-wan proto kernel
unreachable 2001:db8:2::/48 dev pppoe-wan proto static metric 2147483647 pref medium
2001:db8:3::/64 via fe80::3 dev br-lan
2001:db8:4::1 dev br-lan
blackhole 2001:db8:5::/48
ROUTES
 assert_eq $'2001:db8:1::/48\n2001:db8:1:10::/64\n2001:db8:1:20::/64\n2001:db8:2::/48\n2001:db8:4::1' "$(nft_connected_prefixes 6)" 'source-specific defaults, unreachable WAN routes, via routes and hosts'
 sed '/^default/d' "$tmpdir/routes.4" >"$tmpdir/routes.boot"
 mv "$tmpdir/routes.boot" "$tmpdir/routes.4"
 assert_eq $'10.0.2.0/24\n203.0.113.0/24' "$(nft_connected_prefixes 4)" 'no default at boot keeps link subnets'
)
# Restore the exact v4 vector after the boot case.
sed -i '1i default via 10.0.2.2 dev eth1' "$tmpdir/routes.4"


LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
lists_ensure_files
(
 unset SETTINGS_LOADED
 fake_uci_set mihowrt.settings.source_network_interfaces 'br-test wg-test'
 nft() { cp "$2" "$tmpdir/implicit.nft"; }
 nft_apply || fail "nft_apply must load settings implicitly"
 assert_file_contains "$tmpdir/implicit.nft" 'source_ifaces { "br-test" }' "implicit apply uses first UCI source interface"
 assert_file_contains "$tmpdir/implicit.nft" 'source_ifaces { "wg-test" }' "implicit apply uses second UCI source interface"
)
fake_uci_reset
settings_load
POLICY_MODE=direct-first
out="$tmpdir/ruleset.nft"

printf '1.1.1.1\n2001:db8::/32\n9.9.9.9;443\n2606:4700::1;80-90\n;53\n' >"$DST_LIST_FILE"
printf '192.168.1.10\nfd00::10\n' >"$SRC_LIST_FILE"
printf '77.88.8.8\n2a02:6b8::/32\n' >"$DIRECT_DST_LIST_FILE"

render() {
	mkdir -p "$tmpdir/work"
	nft_render "$out" "$tmpdir/work"
}

# Disabled IPv6 must never receive an intercept mark without a local route.
(
 ROUTE_PROC_ROOT="$tmpdir/no-ipv6"
 mkdir -p "$ROUTE_PROC_ROOT/net" "$ROUTE_PROC_ROOT/sys/net/ipv6/conf/all"
 : >"$ROUTE_PROC_ROOT/net/if_inet6"
 echo 1 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/all/disable_ipv6"
 for POLICY_MODE in direct-first proxy-first; do
  render
  assert_file_not_contains "$out" 'tproxy ip6' "$POLICY_MODE has no IPv6 TPROXY without route"
  for chain in prerouting_policy mangle_output; do
   assert_file_contains "$out" "$chain meta nfproto ipv6 return" "$POLICY_MODE/$chain skips disabled IPv6"
   assert_true "$POLICY_MODE/$chain IPv6 guard before marking" awk -v chain="$chain" '
    $5 != chain { next }
    /meta nfproto ipv6 return$/ { guarded = 1 }
    /meta mark set/ && !guarded { exit 1 }
   ' "$out"
  done
 done
 pass 'disabled IPv6 cannot be intercepted'
)

# Replies must leave every policy path before marks or IPv6 rejection.
(
 BLOCK_CLIENT_IPV6=1
 for POLICY_MODE in direct-first proxy-first; do
  render
  for chain in prerouting_policy mangle_output client_ipv6_egress; do
   [ "$chain:$POLICY_MODE" != client_ipv6_egress:proxy-first ] || continue
   assert_file_contains "$out" "$chain ct direction reply return" "$POLICY_MODE/$chain reply guard"
   assert_true "$POLICY_MODE/$chain reply guard before action" awk -v chain="$chain" '
    $5 != chain { next }
    /ct direction reply return$/ { guarded = 1 }
    /meta mark set| reject/ && !guarded { exit 1 }
   ' "$out"
  done
 done
 pass 'reply guards precede marking and client IPv6 rejection in both modes'
)

(
 render
 assert_file_contains "$out" "mangle_output meta mark & 0x000000ff == $MIHOMO_ROUTING_MARK return" 'Mihomo self-bypass ignores foreign mark bits'
 pass 'masked Mihomo self-bypass'
)

# Only newly intercepted traffic reaches the terminal QUIC reject. Earlier
# returns/goto and NetBird's accept keep their existing bypass semantics.
(
 DISABLE_QUIC=1
 NETBIRD_PROXY=1
 DIRECT_LISTENER=1
 printf '192.168.1.50\n' >"$DIRECT_SRC_LIST_FILE"
 for POLICY_MODE in direct-first proxy-first; do
  for DNS_MODE in redir-host fake-ip; do
   render
   for chain in prerouting_policy mangle_output; do
    expected="add rule inet mihowrt $chain meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK udp dport 443 reject"
    assert_eq "$expected" "$(grep "^add rule inet mihowrt $chain " "$out" | tail -n1)" "$POLICY_MODE/$DNS_MODE/$chain terminal QUIC reject"
    assert_eq 1 "$(grep -c "^add rule inet mihowrt $chain .*udp dport 443 reject$" "$out")" 'one QUIC reject per intercept chain'
   done
   assert_file_contains "$out" 'ct direction original meta mark 0x1bd00 meta l4proto { tcp, udp } meta mark set meta mark | 0x08000000 accept' 'NetBird control-plane accept still bypasses QUIC rejection'
   if [ "$POLICY_MODE:$DNS_MODE" = proxy-first:fake-ip ]; then
    assert_file_contains "$out" 'direct_device_policy ip daddr 198.18.0.0/16 udp dport 443 reject' 'direct-device QUIC reject retained before accept'
    assert_file_contains "$out" 'prerouting_policy ip saddr @direct_src goto direct_device_policy' 'goto bypasses terminal policy reject'
   fi
  done
 done
 DISABLE_QUIC=0
 render
 assert_file_not_contains "$out" 'udp dport 443 reject' 'QUIC toggle removes all QUIC rejects'
 pass 'terminal QUIC rejects preserve bypass and direct-device paths'
)

# Router-owned DNS must stay at dnsmasq even outside the discovered local sets.
# 2a00:1::1 is the router's WAN GUA in this fixture; its eth1 prefix is
# deliberately excluded by connected-prefix discovery (unlike RFC1918 LAN IPs).
(
 router_gua=2a00:1::1
 for POLICY_MODE in direct-first proxy-first; do
  for DNS_MODE in fake-ip redir-host; do
   for DNS_HIJACK in 0 1; do
    for BLOCK_CLIENT_IPV6 in 0 1; do
     label="$POLICY_MODE/$DNS_MODE/hijack=$DNS_HIJACK/block=$BLOCK_CLIENT_IPV6"
     render
     assert_file_not_contains "$out" 'localv6 { 2a00:1::/64 }' "$label WAN prefix excluded from localv6"
     assert_file_not_contains "$out" "localv6 { $router_gua }" "$label router WAN GUA not statically excluded"
     grep '^add rule inet mihowrt dns_hijack ' "$out" >"$tmpdir/dns-chain.nft"
     expected="add rule inet mihowrt dns_hijack iifname \"$NETBIRD_INTERFACE\" return
add rule inet mihowrt dns_hijack fib daddr type local return"
     assert_eq "$expected" "$(head -n2 "$tmpdir/dns-chain.nft")" "$label router DNS guard follows NetBird before redirects"
     assert_true "$label router DNS guard precedes every redirect" awk '
      $0 == "add rule inet mihowrt dns_hijack fib daddr type local return" { guarded = 1 }
      / redirect to / && !guarded { exit 1 }
     ' "$tmpdir/dns-chain.nft"
     if [ "$DNS_HIJACK" = 1 ]; then
      expected="$expected
add rule inet mihowrt dns_hijack iifname @source_ifaces ip daddr != @localv4 meta l4proto { tcp, udp } th dport 53 redirect to :$MIHOMO_DNS_PORT"
       expected="$expected
add rule inet mihowrt dns_hijack iifname @source_ifaces ip6 daddr != @localv6 meta l4proto { tcp, udp } th dport 53 redirect to :$MIHOMO_DNS_PORT"
     fi
     assert_eq "$expected" "$(cat "$tmpdir/dns-chain.nft")" "$label DNS redirects otherwise unchanged"
    done
   done
  done
 done
 pass 'router DNS guard precedes redirect'
)

# Resolve only the selected mode's list kinds, even with fake-IP DNS.
(
 lists_resolve() { printf '%s\n' "$1" >>"$tmpdir/resolved-kinds"; }
 for POLICY_MODE in proxy-first direct-first; do
  for DNS_MODE in redir-host fake-ip; do
   : >"$tmpdir/resolved-kinds"
   work="$tmpdir/resolve-$POLICY_MODE-$DNS_MODE"
   mkdir -p "$work"
   nft_render "$tmpdir/resolve.nft" "$work"
   case "$POLICY_MODE" in
    proxy-first) expected=$'direct\ndirect_src' ;;
    direct-first) expected=$'dst\nsrc' ;;
   esac
   assert_eq "$expected" "$(cat "$tmpdir/resolved-kinds")" "$POLICY_MODE skips inactive lists ($DNS_MODE)"
  done
 done
 pass 'proxy-first skips dst src; direct-first skips direct direct_src'
)

# Goldens captured before selective resolution, with inactive lists empty.
# All lists are populated here: inactive data must not affect the ruleset.
(
 printf '192.168.1.50\nfd00::50\n' >"$DIRECT_SRC_LIST_FILE"
 DNS_MODE=redir-host
 for POLICY_MODE in direct-first proxy-first; do
  work="$tmpdir/golden-$POLICY_MODE"
  mkdir -p "$work"
  nft_render "$tmpdir/golden.nft" "$work"
  grep '^add element inet mihowrt localv4 ' "$tmpdir/golden.nft" >"$tmpdir/localv4.nft"
  assert_file_contains "$tmpdir/localv4.nft" '192.88.99.0/24' '6to4 relay range bypassed'
  assert_file_not_contains "$tmpdir/localv4.nft" '198.18.0.0/15' 'benchmark range must not bypass fake-IP interception'
  diff -u "$ROOT_DIR/tests/fixtures/nft/$POLICY_MODE.nft" "$tmpdir/golden.nft"
  assert_file_not_contains "$tmpdir/golden.nft" "$tmpdir" 'ruleset contains no temporary paths'
  pass "$POLICY_MODE ruleset unchanged"
 done
 : >"$DIRECT_SRC_LIST_FILE"
)

render
assert_file_contains "$out" 'localv4 { 203.0.113.0/24 }' 'sets filled: connected v4'
for prefix in 2001:db8:1::/48 2001:db8:1:10::/64 2001:db8:1:20::/64; do
 assert_file_contains "$out" "localv6 { $prefix }" 'sets filled: overlapping delegated v6'
done
assert_file_contains "$out" 'localv4 { 0.0.0.0/8, 10.0.0.0/8,' 'fixed v4 ranges retained'
assert_file_contains "$out" 'localv6 { ::/127, fe80::/10, fc00::/7, ff00::/8 }' 'fixed v6 ranges retained'
pass 'sets filled'
assert_file_contains "$out" "add element inet mihowrt proxy_dst { 1.1.1.1 }" "v4 set element"
assert_file_contains "$out" "add element inet mihowrt proxy_dst6 { 2001:db8::/32 }" "v6 set element"
assert_file_contains "$out" "add element inet mihowrt proxy_src6 { fd00::10 }" "v6 source element"
assert_file_contains "$out" "ip daddr { 9.9.9.9 } meta l4proto { tcp, udp } th dport { 443 } meta mark set" "v4 port rule"
assert_file_contains "$out" "ip6 daddr { 2606:4700::1 } meta l4proto { tcp, udp } th dport { 80-90 } meta mark set" "v6 port rule"
assert_file_contains "$out" "meta nfproto ipv6 meta l4proto { tcp, udp } th dport { 53 }" "port-only v6 rule"
assert_file_contains "$out" "prerouting_policy meta mark & 0x08000000 == 0x08000000 udp dport 443 reject" "QUIC reject after port entry marking"
assert_file_contains "$out" "tproxy ip6 to [::1]:7894" "IPv6 TPROXY"
assert_file_contains "$out" "fib daddr type local return" "local addresses excluded"
assert_file_contains "$out" "ip6 daddr != @localv6 meta l4proto { tcp, udp } th dport 53 redirect to :7874" "IPv6 DNS hijack"
assert_file_contains "$out" "add rule inet mihowrt mangle_output meta l4proto { tcp, udp } th dport 53 return" "router DNS never intercepted"
assert_file_not_contains "$out" "direct_dst6 return" "direct list unused in direct-first"
pass "ruleset v4 and v6"

assert_file_contains "$out" "udp dport 123 return" "NTP bypass on by default"
BYPASS_NTP=0
render
assert_file_not_contains "$out" "udp dport 123 return" "NTP bypass off"
pass "ntp bypass toggle"

POLICY_MODE=proxy-first
render
assert_file_contains "$out" "ip6 daddr @direct_dst6 return" "v6 direct returns"
assert_file_contains "$out" "add rule inet mihowrt prerouting_policy meta l4proto { tcp, udp } meta mark set meta mark | 0x08000000" "catch-all covers both families"
assert_file_not_contains "$out" "meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set" "no IPv4-only catch-all"
pass "proxy-first both families"

NETBIRD_PROXY=1
render
assert_file_contains "$out" "ct direction original meta mark 0x1bd00 meta l4proto { tcp, udp } meta mark set meta mark | 0x08000000 accept" "NetBird capture"
assert_file_contains "$out" "meta mark { 0x1bd10, 0x1bd11, 0x1bd20, 0x1bd21, 0x1bd22 } return" "NetBird dataplane bypass"
pass "netbird rules kept"

# NetBird bypass must not send fake-IP destinations to WAN.
(
 NETBIRD_PROXY=0
 marks='0x1bd00, 0x1bd10, 0x1bd11, 0x1bd20, 0x1bd21, 0x1bd22'
 for POLICY_MODE in direct-first proxy-first; do
  for DNS_MODE in fake-ip redir-host; do
   render
   if [ "$DNS_MODE" = fake-ip ]; then
    assert_file_not_contains "$out" "mangle_output meta mark { $marks } return" "$POLICY_MODE fake-IP has no unconditional NetBird return"
    assert_file_contains "$out" "mangle_output meta nfproto ipv6 meta mark { $marks } return" "$POLICY_MODE IPv6 NetBird bypass"
    assert_file_contains "$out" "mangle_output ip daddr != $FAKEIP_RANGE meta mark { $marks } return" "$POLICY_MODE real-IP NetBird bypass"
    assert_true "$POLICY_MODE fake-IP reaches interception after NetBird guards" awk '
     $5 != "mangle_output" { next }
     /ip daddr != .* meta mark \{/ { guarded = 1 }
     /meta mark set/ { if (!guarded) exit 1; seen = 1 }
     END { if (!seen) exit 1 }
    ' "$out"
   else
    assert_file_contains "$out" "mangle_output meta mark { $marks } return" "$POLICY_MODE redir-host keeps NetBird bypass"
   fi
  done
 done
 pass 'NetBird bypass preserves fake-IP interception in both policy modes'
)

(
 for POLICY_MODE in direct-first proxy-first; do
  for NETBIRD_PROXY in 0 1; do
   render
   assert_file_not_contains "$out" 'ct direction reply meta mark' 'NetBird has no redundant reply guard'
   assert_true "$POLICY_MODE/$NETBIRD_PROXY reply return precedes NetBird output rules" awk '
    $5 != "mangle_output" { next }
    /ct direction reply return$/ { guarded = 1 }
    /meta mark (\{|0x1bd00)/ { seen = 1; if (!guarded) exit 1 }
    END { if (!seen) exit 1 }
   ' "$out"
  done
 done
 pass 'shared output reply return precedes every NetBird path'
)

if command -v nft >/dev/null 2>&1 && nft -c -f "$out" 2>/dev/null; then
	pass "nft accepts ruleset"
else
	printf 'skip - nft syntax check (needs nft with kernel support)\n'
fi

# Temporary subscription bypass: router traffic only, sets with timeouts.
render
assert_file_contains "$out" "add set inet mihowrt bypass_dst { type ipv4_addr; flags timeout; }" "v4 bypass set"
assert_file_contains "$out" "add set inet mihowrt bypass_dst6 { type ipv6_addr; flags timeout; }" "v6 bypass set"
assert_file_contains "$out" "add rule inet mihowrt mangle_output ip daddr @bypass_dst return" "router traffic bypass v4"
assert_file_contains "$out" "add rule inet mihowrt mangle_output ip6 daddr @bypass_dst6 return" "router traffic bypass v6"
assert_file_not_contains "$out" "prerouting_policy ip daddr @bypass_dst" "LAN clients are not affected"
pass "bypass sets for router traffic only"

BYPASS_NTP=1
DNS_MODE=redir-host
POLICY_MODE=proxy-first
printf '192.168.1.50\nfd00::50\n' >"$DIRECT_SRC_LIST_FILE"
render
assert_eq $'add table inet mihowrt\ndelete table inet mihowrt\nadd table inet mihowrt' "$(head -n3 "$out")" "atomic table replacement"
assert_file_contains "$out" 'meta nfproto ipv6 udp dport 123 return' "IPv6 NTP bypass"
assert_file_contains "$out" 'ip daddr != 198.18.0.0/16 udp dport 123 return' "fake-IP NTP intercepted"
assert_false "no unconditional NTP bypass" grep -Eq '^add rule .* (prerouting_policy|mangle_output) udp dport 123 return$' "$out"
assert_file_contains "$out" 'ip saddr @direct_src return' "direct devices bypass"
assert_file_contains "$out" 'ip6 saddr @direct_src6 return' "IPv6 direct devices bypass"
a=$(grep -n 'prerouting_policy ip saddr @direct_src return' "$out" | cut -d: -f1)
b=$(grep -n 'prerouting_policy meta l4proto { tcp, udp } meta mark set' "$out" | cut -d: -f1)
assert_true "device return precedes catch-all" test "$a" -lt "$b"
DNS_MODE=fake-ip
DIRECT_LISTENER=1
render
assert_file_contains "$out" 'ip saddr @direct_src goto direct_device_policy' "fake-IP sends direct devices through split policy"
nft() { echo "$*" >>"$tmpdir/nft.calls"; }
table_present=1
nft_active() { [ "$table_present" = 1 ]; }
nft_apply
nft_apply
assert_eq 1 "$(wc -l <"$tmpdir/nft.calls" | tr -d ' ')" "identical apply skipped"
table_present=0
nft_apply
assert_eq 2 "$(wc -l <"$tmpdir/nft.calls" | tr -d ' ')" "missing table reapplied"
table_present=1
printf '8.8.8.8\n' >>"$DIRECT_DST_LIST_FILE"
nft_apply
assert_eq 3 "$(wc -l <"$tmpdir/nft.calls" | tr -d ' ')" "changed list reapplied"
pass "NTP, direct devices, atomic and no-op nft apply"

POLICY_MODE=direct-first
DISABLE_QUIC=1
printf 'AA:BB:CC:DD:EE:FF\n' >"$SRC_LIST_FILE"
render
assert_file_contains "$out" 'add set inet mihowrt proxy_src_mac { type ether_addr; }' 'proxy MAC set'
assert_file_contains "$out" 'add set inet mihowrt direct_src_mac { type ether_addr; }' 'direct MAC set'
assert_file_contains "$out" 'add element inet mihowrt proxy_src_mac { aa:bb:cc:dd:ee:ff }' 'MAC element'
a=$(grep -n 'prerouting_policy ether saddr @proxy_src_mac meta l4proto' "$out" | cut -d: -f1)
b=$(grep -n 'prerouting_policy meta mark & 0x08000000 == 0x08000000 udp dport 443 reject' "$out" | cut -d: -f1)
assert_true 'MAC mark precedes terminal QUIC reject' test "$a" -lt "$b"
assert_file_not_contains "$out" 'mangle_output ether saddr' 'no Ethernet source matching for router output'
DISABLE_QUIC=0
render
assert_file_not_contains "$out" 'ether saddr @proxy_src_mac udp dport 443 reject' 'MAC QUIC reject disabled'
POLICY_MODE=proxy-first
DNS_MODE=redir-host
printf 'aa:bb:cc:dd:ee:ff\n' >"$DIRECT_SRC_LIST_FILE"
render
assert_file_contains "$out" 'add element inet mihowrt direct_src_mac { aa:bb:cc:dd:ee:ff }' 'direct MAC element'
a=$(grep -n 'prerouting_policy ether saddr @direct_src_mac return' "$out" | cut -d: -f1)
b=$(grep -n 'prerouting_policy meta l4proto { tcp, udp } meta mark set' "$out" | cut -d: -f1)
assert_true 'MAC return precedes catch-all' test "$a" -lt "$b"
# Use the external binary: nft() above is an apply spy.
if type -P nft >/dev/null 2>&1; then
 command nft -c -f "$out"
else
 printf 'skip - nft not installed; real syntax check deferred to Task 24 VM\n'
fi
DNS_MODE=fake-ip
render
assert_file_contains "$out" 'ether saddr @direct_src_mac goto direct_device_policy' 'fake-IP handles direct MAC devices'
pass 'MAC device nft rules'

(
 : >"$SRC_LIST_FILE"
 : >"$DIRECT_SRC_LIST_FILE"
 DISABLE_QUIC=1
 for POLICY_MODE in direct-first proxy-first; do
  for DNS_MODE in fake-ip redir-host; do
   render
   assert_file_not_contains "$out" 'ether saddr' "$POLICY_MODE/$DNS_MODE empty MAC lists emit no Ethernet source rule"
  done
 done
)
pass 'empty MAC lists emit no ether saddr rules'

# Enabling/disabling the boundary uses the same single atomic replacement.
(
 nft() {
  printf '%s\n' "$*" >>"$tmpdir/boundary-apply.calls"
  cp "$2" "$tmpdir/boundary-transaction.nft"
 }
 nft_active() { return 0; }
 rm -f "$NFT_APPLIED_FILE"
 : >"$tmpdir/boundary-apply.calls"
 POLICY_MODE=direct-first
 for BLOCK_CLIENT_IPV6 in 0 1 0; do
  nft_apply
  assert_eq $'add table inet mihowrt\ndelete table inet mihowrt\nadd table inet mihowrt' "$(head -n3 "$tmpdir/boundary-transaction.nft")" 'toggle stays atomic'
  if [ "$BLOCK_CLIENT_IPV6" = 1 ]; then
   assert_file_contains "$tmpdir/boundary-transaction.nft" client_ipv6_egress 'enabled transaction includes boundary'
  else
   assert_file_not_contains "$tmpdir/boundary-transaction.nft" client_ipv6_egress 'disabled transaction removes boundary'
  fi
 done
 assert_eq 3 "$(wc -l <"$tmpdir/boundary-apply.calls" | tr -d ' ')" 'one nft invocation per toggle'
 assert_eq 3 "$(grep -c '^-f ' "$tmpdir/boundary-apply.calls")" 'only nft -f, no separate deletes'
 : >"$tmpdir/boundary-apply.calls"
 nft() { printf '%s\n' "$*" >>"$tmpdir/boundary-apply.calls"; return 1; }
 BLOCK_CLIENT_IPV6=1
 if nft_apply 2>"$tmpdir/boundary-apply.err"; then fail 'failed transaction must report failure'; fi
 assert_eq "-f $PKG_TMP_DIR/nft/ruleset.nft" "$(cat "$tmpdir/boundary-apply.calls")" 'failed transaction not retried or deleted'
 assert_file_contains "$tmpdir/boundary-apply.err" 'Failed to apply nftables policy' 'failure reported'
 assert_false 'failed apply invalidates comparison cache' test -e "$NFT_APPLIED_FILE"
 assert_true 'failed rendered transaction retained for diagnosis' test -s "$PKG_TMP_DIR/nft/ruleset.nft"
)
pass 'client IPv6 toggle and failed transaction stay atomic'

# A missing include must not invoke cmp (BusyBox emits errors even with -s).
(
 rm -f "$FW4_INPUT_INCLUDE"
 SOURCE_INTERFACES=br-guest
 cmp() { printf 'called\n' >>"$tmpdir/include-cmp.calls"; busybox cmp "$@"; }
 fw4() { :; }
 nft_fw4_input_apply 2>"$tmpdir/include-first.err"
 assert_false 'missing include skips cmp' test -e "$tmpdir/include-cmp.calls"
 assert_false 'first include creation has no cmp stderr' test -s "$tmpdir/include-first.err"
 cmp() { printf 'cmp read error\n' >&2; return 1; }
 nft_fw4_input_apply 2>"$tmpdir/include-compare.err"
 assert_false 'include comparison suppresses cmp errors' test -s "$tmpdir/include-compare.err"
 rm -f "$FW4_INPUT_INCLUDE"
)
pass 'fw4 include compares only existing files without stderr noise'

# Empty source interfaces still need the mark accept, never an empty nft set.
(
 fw4() { :; }
 for SOURCE_INTERFACES in '' $' \t\n '; do
  nft_fw4_input_apply
  assert_eq "meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK accept" "$(cat "$FW4_INPUT_INCLUDE")" 'empty interfaces emit only the mark accept'
 done
 rm -f "$FW4_INPUT_INCLUDE"
)
pass 'fw4 include omits DNS rule for empty or whitespace-only interfaces'

# fw4 input policy must admit intercepted guest traffic, without repeat writes.
(
 settings_require() { :; }
 SOURCE_INTERFACES='br-guest br-iot'
 NFT_INTERCEPT_MARK=0x10000000
 MIHOMO_DNS_PORT=8853
 nft_input_hash() { printf 'fixed inputs\n'; }
 nft_render() { printf 'fixed transaction\n' >"$1"; }
 nft_active() { return 0; }
 nft() { :; }
 fw4() {
  for fd in 6 7 8 9; do
   assert_false "fw4 does not inherit lock fd $fd" test -e "/proc/$BASHPID/fd/$fd"
  done
  printf '%s\n' "$*" >>"$tmpdir/fw4.calls"
 }
 exec 6>"$tmpdir/fw4.lock6" 7>"$tmpdir/fw4.lock7" 8>"$tmpdir/fw4.lock8" 9>"$tmpdir/fw4.lock9"
 nft_apply
 exec 6>&- 7>&- 8>&- 9>&-
 expected="meta mark & $NFT_INTERCEPT_MARK == $NFT_INTERCEPT_MARK accept
iifname { \"br-guest\", \"br-iot\" } meta l4proto {tcp,udp} th dport $MIHOMO_DNS_PORT ct status dnat accept"
 assert_eq "$expected" "$(cat "$FW4_INPUT_INCLUDE" 2>/dev/null || :)" 'fw4 include uses intercept mark, source interfaces and DNS port'
 assert_eq reload "$(cat "$tmpdir/fw4.calls")" 'changed include reloads fw4 once'
 touch -d '2024-01-01 00:00:00' "$FW4_INPUT_INCLUDE"
 before="$(stat -c '%i:%Y' "$FW4_INPUT_INCLUDE")"
 nft_apply
 assert_eq "$before" "$(stat -c '%i:%Y' "$FW4_INPUT_INCLUDE")" 'identical include is not rewritten'
 assert_eq reload "$(cat "$tmpdir/fw4.calls")" 'identical include does not reload fw4'
 rm "$FW4_INPUT_INCLUDE"
 nft_apply
 assert_eq "$expected" "$(cat "$FW4_INPUT_INCLUDE")" 'cached nft inputs repair a missing include'
 assert_eq 2 "$(wc -l <"$tmpdir/fw4.calls")" 'missing include reloads fw4 once'
 SOURCE_INTERFACES=br-new
 logger() { printf '%s\n' "$*" >>"$tmpdir/fw4.warnings"; }
 fw4() {
  printf '%s\n' "$*" >>"$tmpdir/fw4.calls"
  printf 'ignored stdout\n'
  printf 'reload rejected: test reason\nsecond error line\n' >&2
  return 1
 }
 nft_apply 2>"$tmpdir/fw4.err" || fail 'fw4 reload failure must not fail start'
 assert_false 'rejected include is rolled back off flash' test -e "$FW4_INPUT_INCLUDE"
 assert_eq 4 "$(wc -l <"$tmpdir/fw4.calls")" 'failed reload is followed by a reload without the include'
 assert_file_contains "$tmpdir/fw4.warnings" 'Failed to reload firewall4 input rules: reload rejected: test reason' 'fw4 reload failure warns with first stderr line'
 assert_file_not_contains "$tmpdir/fw4.warnings" 'second error line' 'reload warning omits later stderr lines'
 assert_file_not_contains "$tmpdir/fw4.warnings" 'ignored stdout' 'reload warning omits stdout'
 fw4() { printf '%s\n' "$*" >>"$tmpdir/fw4.calls"; }
 nft_apply
 assert_file_contains "$FW4_INPUT_INCLUDE" 'iifname { "br-new" }' 'changed interfaces update include'
 fw4() {
  printf '%s\n' "$*" >>"$tmpdir/fw4.calls"
  printf 'reload rejected: test reason\nsecond error line\n' >&2
  return 1
 }
 SOURCE_INTERFACES=br-failed
 before="$(cat "$FW4_INPUT_INCLUDE")"
 atomic_write() { return 1; }
 nft_apply || fail 'failed include write must not fail nft_apply'
 assert_file_contains "$tmpdir/fw4.warnings" 'Failed to write firewall4 input rules' 'failed include write warns'
 assert_eq "$before" "$(cat "$FW4_INPUT_INCLUDE")" 'failed include write preserves previous include'
 assert_eq 5 "$(wc -l <"$tmpdir/fw4.calls")" 'failed include write does not reload'
 : >"$tmpdir/fw4.warnings"
 nft_fw4_input_cleanup || fail 'cleanup reload failure must remain nonfatal'
 assert_false 'cleanup removes include despite reload failure' test -e "$FW4_INPUT_INCLUDE"
 assert_file_contains "$tmpdir/fw4.warnings" 'Failed to reload firewall4 input rules: reload rejected: test reason' 'cleanup warning carries first stderr line'
 assert_file_not_contains "$tmpdir/fw4.warnings" 'second error line' 'cleanup warning omits later stderr lines'
 rm -f "$NFT_APPLIED_FILE" "$NFT_APPLIED_FILE.inputs"
)
pass 'fw4 input include is dynamic, change-only and nonfatal on write or reload failure'

# Duplicate interface names must not reach the include.
(
 fw4() { :; }
 nft() { :; }
 SOURCE_INTERFACES='br-a br-b br-a'
 rm -f "$FW4_INPUT_INCLUDE"
 nft_fw4_input_apply
 assert_file_contains "$FW4_INPUT_INCLUDE" 'iifname { "br-a", "br-b" }' 'include lists each interface once'
 rm -f "$FW4_INPUT_INCLUDE"
)
pass 'fw4 include dedupes interface names'
