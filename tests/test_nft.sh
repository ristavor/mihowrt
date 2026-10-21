#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh nft.sh
setup_runtime_paths "$tmpdir"


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

render
assert_file_contains "$out" "add element inet mihowrt proxy_dst { 1.1.1.1 }" "v4 set element"
assert_file_contains "$out" "add element inet mihowrt proxy_dst6 { 2001:db8::/32 }" "v6 set element"
assert_file_contains "$out" "add element inet mihowrt proxy_src6 { fd00::10 }" "v6 source element"
assert_file_contains "$out" "ip daddr 9.9.9.9 meta l4proto { tcp, udp } th dport { 443 } meta mark set" "v4 port rule"
assert_file_contains "$out" "ip6 daddr 2606:4700::1 meta l4proto { tcp, udp } th dport { 80-90 } meta mark set" "v6 port rule"
assert_file_contains "$out" "meta nfproto ipv6 meta l4proto { tcp, udp } th dport { 53 }" "port-only v6 rule"
assert_file_contains "$out" "ip daddr 9.9.9.9 udp dport 443 reject" "QUIC reject for port entry with 443"
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
render
assert_file_not_contains "$out" 'saddr @direct_src' "fake-IP disables direct devices"
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
a=$(grep -n 'prerouting_policy ether saddr @proxy_src_mac udp dport 443 reject' "$out" | cut -d: -f1)
b=$(grep -n 'prerouting_policy ether saddr @proxy_src_mac meta l4proto { tcp, udp } meta mark set meta mark | 0x08000000' "$out" | cut -d: -f1)
assert_true 'MAC QUIC reject precedes mark' test "$a" -lt "$b"
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
assert_file_not_contains "$out" 'ether saddr @direct_src_mac return' 'fake-IP skips direct MAC devices'
pass 'MAC device nft rules'
