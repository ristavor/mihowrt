#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh dns.sh
setup_runtime_paths "$tmpdir"


PKG_TMP_DIR="$tmpdir/tmp"
DNS_AUTO_RESOLVFILE="$tmpdir/resolv.conf.auto"
RUNNING_MARKER="$tmpdir/running"
restarts="$tmpdir/restarts"
: >"$restarts"
dns_restart_dnsmasq() {
	echo restart >>"$restarts"
}

fake_uci_set dhcp.cfg01 dnsmasq
fake_uci_set dhcp.cfg01.confdir "$tmpdir/dnsmasq.d"
fake_uci_set dhcp.cfg01.server "'9.9.9.9'"
fake_uci_set system.ntp.server '0.openwrt.pool.ntp.org 192.0.2.10'
BYPASS_NTP=1
BYPASS_SUBSCRIPTION_DNS=1
SUBSCRIPTION_URL='https://user@sub.example.com:8443/path?x=1'
printf '# Interface wan\nnameserver 10.0.0.1\nnameserver 127.0.0.1\n' >"$DNS_AUTO_RESOLVFILE"

dns_render "$tmpdir/out"
assert_eq "no-resolv" "$(sed -n 1p "$tmpdir/out")" "first line"
assert_eq "server=127.0.0.1#7874" "$(sed -n 2p "$tmpdir/out")" "Mihomo server line"
assert_file_contains "$tmpdir/out" "server=/0.openwrt.pool.ntp.org/10.0.0.1" "NTP bypass"
assert_file_contains "$tmpdir/out" "server=/sub.example.com/10.0.0.1" "subscription bypass"
assert_file_not_contains "$tmpdir/out" "192.0.2.10" "IP NTP servers need no bypass"
assert_file_not_contains "$tmpdir/out" "/127.0.0.1" "loopback ISP DNS skipped"
pass "render with bypass"

BYPASS_NTP=0
dns_render "$tmpdir/out"
assert_file_not_contains "$tmpdir/out" "ntp.org" "NTP toggle off"
BYPASS_NTP=1
: >"$DNS_AUTO_RESOLVFILE"
dns_render "$tmpdir/out"
assert_eq 2 "$(wc -l <"$tmpdir/out" | tr -d ' ')" "no bypass without ISP DNS"
pass "render without isp"

printf 'nameserver 10.0.0.1\n' >"$DNS_AUTO_RESOLVFILE"
dns_apply || fail "apply must succeed"
[[ -f "$tmpdir/dnsmasq.d/mihowrt.conf" ]] || fail "conf file missing"
dns_apply
assert_eq 1 "$(wc -l <"$restarts" | tr -d ' ')" "second apply must not restart dnsmasq"
pass "apply idempotent"

dns_cleanup
[[ ! -e "$tmpdir/dnsmasq.d/mihowrt.conf" ]] || fail "conf file must be removed"
assert_eq 2 "$(wc -l <"$restarts" | tr -d ' ')" "cleanup restarts once"
dns_cleanup
assert_eq 2 "$(wc -l <"$restarts" | tr -d ' ')" "clean cleanup is a no-op"
pass "cleanup removes file"

assert_eq "9.9.9.9" "$(trim "$(dns_custom_servers)")" "custom dnsmasq servers reported"
pass "custom servers detected"

fake_uci_set system.ntp.server 'good.ntp.org bad/host evil#x'
BYPASS_SUBSCRIPTION_DNS=0
assert_eq "good.ntp.org" "$(dns_bypass_hosts)" "only plain host names reach dnsmasq"
pass "bypass host names sanitized"

: >"$restarts"
echo "$$" >"$RUNNING_MARKER"
service_running() { return 1; }
settings_load() { :; }
net_refresh
[[ ! -e "$tmpdir/dnsmasq.d/mihowrt.conf" ]] || fail "refresh must not point dnsmasq at a Mihomo that is not running"
pass "net refresh requires running service"

# A failed dns_apply must not skip nft_apply (new prefixes), and still fails.
echo "$$" >"$RUNNING_MARKER"
service_running() { return 0; }
settings_load() { :; }
dns_apply() { return 1; }
nft_calls=0
nft_apply() { nft_calls=$((nft_calls + 1)); return 0; }
assert_false "net refresh reports dns failure" net_refresh
assert_eq 1 "$nft_calls" "nft_apply still runs after dns_apply failure"
dns_apply() { return 0; }
nft_apply() { return 1; }
assert_false "net refresh reports nft failure" net_refresh
pass "net refresh keeps nft"
