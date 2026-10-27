#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh dns.sh
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

assert_eq "9.9.9.9" "$(dns_custom_servers | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" "custom dnsmasq servers reported"
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
nft_connected_prefixes() { :; }
dns_apply() { return 1; }
nft_calls=0
nft_apply() { nft_calls=$((nft_calls + 1)); return 0; }
assert_false "net refresh reports dns failure" net_refresh
assert_eq 1 "$nft_calls" "nft_apply still runs after dns_apply failure"
dns_apply() { return 0; }
nft_apply() { return 1; }
assert_false "net refresh reports nft failure" net_refresh
pass "net refresh keeps nft"

# A separate shell owns fd 6, so busy checks use a real competing flock.
start_net_refresh_holder() {
	ash -c '
		exec 6>>"$1/net-refresh.flock"
		flock -n 6 || exit 1
		: >"$1/holder.ready"
		exec sleep 300
	' ash "$PKG_STATE_DIR" 6>&- 9>&- &
	holder=$!
	for i in {1..100}; do
		[ ! -e "$PKG_STATE_DIR/holder.ready" ] || return 0
		sleep 0.02
	done
	fail 'net-refresh holder did not become ready'
}

test_net_refresh_coalesced() (
	local scenario="$1" calls=0 rc=0 holder="" injected=0 busy_pid="" i
	PKG_STATE_DIR="$tmpdir/coalesced-$scenario"
	RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
	NET_REFRESH_DELAY=0
	mkdir -p "$PKG_STATE_DIR"
	trap 'if [ -n "$holder" ]; then kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true; fi' EXIT
	declare -F net_refresh_coalesced >/dev/null || fail 'net_refresh_coalesced missing'
	if [ "$scenario" = debounce ] || [ "$scenario" = default-delay ]; then
		[ "$scenario" != default-delay ] || unset NET_REFRESH_DELAY
		sleep() {
			if [ "$scenario" = default-delay ]; then
				assert_eq 2 "$1" 'default coalescing delay is two seconds'
			else
				assert_eq 0 "$1" 'environment overrides coalescing delay'
			fi
			: >"$PKG_STATE_DIR/net-refresh.pending"
		}
	fi
	net_refresh() {
		assert_eq 1 "$LOCK_DEPTH" 'refresh runs under runtime lock'
		calls=$((calls + 1))
		case "$scenario:$calls" in
		pending:1 | last-success:1 | last-failure:1) : >"$PKG_STATE_DIR/net-refresh.pending" ;;
		esac
		case "$scenario:$calls" in
		last-success:1 | last-failure:2 | retry-busy:1) return 7 ;;
		esac
		return 0
	}
	flock() {
		command flock "$@" || return $?
		# Inject exactly after the last pending check, at unlock.
		if [ "$*" = '-u 6' ] && [ "$injected" = 0 ]; then
			case "$scenario" in
			unlock-window | retry-busy)
				injected=1
				: >"$PKG_STATE_DIR/net-refresh.pending"
				[ "$scenario" != retry-busy ] || start_net_refresh_holder
				;;
			esac
		fi
	}
	if [ "$scenario" = busy ]; then
		start_net_refresh_holder
		# A busy event must finish while the holder is still alive.
		(
			net_refresh_coalesced || exit 1
			[ "$calls" = 0 ] || exit 1
			[ ! -e /dev/fd/6 ] || exit 1
			: >"$PKG_STATE_DIR/busy.done"
		) &
		busy_pid=$!
		for i in {1..100}; do
			[ ! -e "$PKG_STATE_DIR/busy.done" ] || break
			sleep 0.02
		done
		if [ ! -e "$PKG_STATE_DIR/busy.done" ]; then
			kill "$busy_pid" 2>/dev/null || true
			wait "$busy_pid" 2>/dev/null || true
			fail 'busy refresh must exit 0 without waiting or calling net_refresh'
		fi
		wait "$busy_pid"
		assert_true 'busy event leaves pending' test -f "$PKG_STATE_DIR/net-refresh.pending"
		return 0
	fi
	net_refresh_coalesced || rc=$?
	assert_false 'coalescer closes fd 6' test -e /dev/fd/6
	assert_false 'coalescer releases runtime lock' lock_busy
	if [ "$scenario" = retry-busy ]; then
		assert_eq 1 "$calls" 'retry-busy does not refresh under another owner'
		assert_eq 7 "$rc" 'retry-busy preserves last refresh rc'
		assert_true 'retry-busy leaves pending for new owner' test -f "$PKG_STATE_DIR/net-refresh.pending"
		return 0
	fi
	assert_true 'coalescing lock released' bash -c 'exec 6>>"$1/net-refresh.flock"; flock -n 6' bash "$PKG_STATE_DIR"
	assert_false 'no pending file after refresh' test -e "$PKG_STATE_DIR/net-refresh.pending"
	case "$scenario" in
	single | debounce | default-delay) assert_eq 1 "$calls" 'single event refreshes once' ;;
	*) assert_eq 2 "$calls" 'pending event refreshes exactly twice' ;;
	esac
	if [ "$scenario" = last-failure ]; then
		assert_eq 7 "$rc" 'last failed refresh rc returned'
	else
		assert_eq 0 "$rc" 'last successful refresh rc returned'
	fi
)

coalesced_failures=0
for scenario in single pending busy last-success last-failure unlock-window retry-busy debounce default-delay; do
	if test_net_refresh_coalesced "$scenario"; then
		pass "net_refresh_coalesced $scenario"
	else
		coalesced_failures=$((coalesced_failures + 1))
	fi
done

# Execute the real init-call helper with both held locks, not the restart stub.
sed "s|/etc/init.d/dnsmasq|$tmpdir/dnsmasq-init|g" "$MIHOWRT_LIB_DIR/dns.sh" >"$tmpdir/dns-init.sh"
cat >"$tmpdir/dnsmasq-init" <<'INIT'
#!/bin/sh
[ ! -e /proc/$$/fd/6 ] && [ ! -e /proc/$$/fd/9 ]
INIT
chmod +x "$tmpdir/dnsmasq-init"
if ash -c '
	. "$1/dns-init.sh"
	exec 6>>"$1/init-net.flock"
	flock -n 6 || exit 1
	exec 9>>"$1/init-runtime.flock"
	flock -n 9 || exit 1
	dns_restart_dnsmasq
' ash "$tmpdir"; then
	pass 'dnsmasq init closes fd 6 and fd 9'
else
	echo 'FAIL: dnsmasq init must not inherit fd 6 or fd 9' >&2
	coalesced_failures=$((coalesced_failures + 1))
fi
assert_eq 0 "$coalesced_failures" 'coalescing regression failures'
