#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh route.sh
setup_runtime_paths "$tmpdir"


# A compiled IPv6 stack is not necessarily enabled on the loopback route.
(
 ROUTE_PROC_ROOT="$tmpdir/proc-families"
 mkdir -p "$ROUTE_PROC_ROOT/net" "$ROUTE_PROC_ROOT/sys/net/ipv6/conf/"{all,lo}
 assert_eq 4 "$(route_families)" 'missing IPv6 stack'
 : >"$ROUTE_PROC_ROOT/net/if_inet6"
 for disabled in all lo neither; do
  echo 0 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/all/disable_ipv6"
  echo 0 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/lo/disable_ipv6"
  [ "$disabled" = neither ] || echo 1 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/$disabled/disable_ipv6"
  expected=4
  [ "$disabled" != neither ] || expected=$'4\n6'
  assert_eq "$expected" "$(route_families)" "IPv6 disabled on $disabled"
 done
 pass 'route families respect all and loopback IPv6 disable flags'
)

ROUTE_STATE_FILE="$tmpdir/route.state"
calls="$tmpdir/calls"
: >"$calls"
ip() {
	echo "ip $*" >>"$calls"
	case "$*" in
	"-4 route show table all") echo "local 1.2.3.4 dev lo table 200 proto kernel" ;;
	"-4 rule show") printf '0:\tfrom all lookup local\n50:\tfrom all lookup 201\n' ;;
	"-4 rule del"*) return 1 ;;
	"-6 rule del"*) return 1 ;;
	esac
	return 0
}
ROUTE_PROC_ROOT="$tmpdir/proc"
mkdir -p "$ROUTE_PROC_ROOT/net"
rm -f "$ROUTE_PROC_ROOT/net/if_inet6"

route_setup || fail "setup must succeed"
assert_file_contains "$ROUTE_STATE_FILE" "TABLE=202" "first free table skips used ids"
assert_file_contains "$ROUTE_STATE_FILE" "PRIORITY=51" "first free priority"
assert_file_contains "$calls" "ip -4 rule add fwmark 0x08000000/0x08000000 lookup 202 priority 51" "v4 rule added"
assert_file_not_contains "$calls" "ip -6" "no IPv6 calls without IPv6"
pass "route v6 skipped without IPv6"

: >"$calls"
: >"$ROUTE_PROC_ROOT/net/if_inet6"
route_setup
assert_file_contains "$calls" "ip -6 route replace local default dev lo table 202" "v6 local route"
assert_file_contains "$calls" "ip -6 rule add fwmark 0x08000000/0x08000000 lookup 202 priority 51" "v6 rule"
pass "route v6 added with IPv6"

: >"$calls"
route_cleanup
assert_file_contains "$calls" "ip -4 rule del fwmark 0x08000000/0x08000000 lookup 202 priority 51" "current mark rule removed"
assert_file_not_contains "$calls" "0x00001000" "runtime cleanup must not remove legacy mark rules"
assert_file_contains "$calls" "ip -6 route flush table 202" "v6 table flushed"
# BusyBox ip (OpenWrt 24.10) accepts "route flush" for IPv6 but removes nothing:
# the route is deleted by value so its table is not counted as used forever.
assert_file_contains "$calls" "ip -6 route del local default dev lo table 202" "v6 local route deleted"
assert_file_contains "$calls" "ip -4 route del local default dev lo table 202" "v4 local route deleted"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "state removed"
pass "route cleanup"

# Stop must remove routes installed before IPv6 was disabled or disappeared.
for disabled in all lo missing; do
 route_setup
 if [ "$disabled" = missing ]; then
  rm -f "$ROUTE_PROC_ROOT/net/if_inet6"
 else
  echo 1 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/$disabled/disable_ipv6"
 fi
 : >"$calls"
 route_cleanup
 for family in 4 6; do
  assert_file_contains "$calls" "ip -$family rule del fwmark 0x08000000/0x08000000 lookup 202 priority 51" "IPv$family rule removed after IPv6 disabled on $disabled"
  assert_file_contains "$calls" "ip -$family route flush table 202" "IPv$family table flushed after IPv6 disabled on $disabled"
 done
 [[ ! -e "$ROUTE_STATE_FILE" ]] || fail 'disabled IPv6 cleanup removes state'
 : >"$ROUTE_PROC_ROOT/net/if_inet6"
 echo 0 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/all/disable_ipv6"
 echo 0 >"$ROUTE_PROC_ROOT/sys/net/ipv6/conf/lo/disable_ipv6"
done
pass 'route cleanup removes both families even after IPv6 is disabled'

# Cleanup must use the old priority, not the replacement allocation.
printf 'TABLE=202\nPRIORITY=1000\n' >"$ROUTE_STATE_FILE"
: >"$calls"
route_setup
assert_file_contains "$calls" 'rule del fwmark 0x08000000/0x08000000 lookup 202 priority 1000' 'stored out-of-range rule cleaned with old priority'
assert_file_contains "$ROUTE_STATE_FILE" 'PRIORITY=51' 'old priority reallocated before foreign policy rules'
assert_file_contains "$calls" 'rule add fwmark 0x08000000/0x08000000 lookup 202 priority 51' 'replacement priority installed'
pass 'legacy priority cleaned and reallocated'

for legacy in OLD_NFT_INTERCEPT_MARK 'ROUTE_TABLE_ID=' 'ROUTE_RULE_PRIORITY='; do
 assert_file_not_contains "$MIHOWRT_LIB_DIR/route.sh" "$legacy" "route runtime has no legacy"
done
pass "route runtime has no legacy"
