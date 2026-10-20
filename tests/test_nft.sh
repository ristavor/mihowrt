#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh lists.sh nft.sh

LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst.txt"
SRC_LIST_FILE="$LIST_DIR/src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct.txt"
POLICY_CACHE_DIR="$tmpdir/cache"
lists_ensure_files
settings_load
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
