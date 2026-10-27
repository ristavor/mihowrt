#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh nft.sh route.sh dns.sh service.sh
setup_runtime_paths "$tmpdir"
POLICY_MODE=direct-first
DNS_AUTO_RESOLVFILE="$tmpdir/resolv"
NET_FP_FILE="$PKG_STATE_DIR/net.fp"
RUNNING_MARKER="$PKG_STATE_DIR/running"
touch "$RUNNING_MARKER"
service_running() { return 0; }
nft_active() { return 0; }
settings_load() { :; }
printf 'nameserver 10.0.0.1\n' >"$DNS_AUTO_RESOLVFILE"
printf '203.0.113.0/24 dev br-lan\n' >"$tmpdir/routes.4"
printf '2001:db8:1::/64 dev br-lan\n' >"$tmpdir/routes.6"
ip() {
 case "$*" in
 '-4 route show table main') cat "$tmpdir/routes.4" ;;
 '-6 route show table main') cat "$tmpdir/routes.6" ;;
 '-4 route show default' | '-6 route show default') : ;;
 *) fail "unexpected ip arguments: $*" ;;
 esac
}
events="$tmpdir/events"

check_refresh() (
 local scenario="$1" rc=0
 rm -f "$NET_FP_FILE"
 : >"$events"
 dns_apply() { echo dns >>"$events"; }
 nft_apply() { echo nft >>"$events"; }
 net_refresh
 case "$scenario" in
 same)
  : >"$events"
  net_refresh
  assert_eq '' "$(cat "$events")" 'same fingerprint skips both renderers'
  ;;
 table_missing)
  : >"$events"
  nft_active() { return 1; }
  net_refresh
  assert_eq $'dns\nnft' "$(cat "$events")" 'missing policy table refreshes despite same fingerprint'
  ;;
 prefix4 | prefix6 | dns)
  : >"$events"
  case "$scenario" in
  prefix4) printf '198.51.100.0/24 dev br-guest\n' >>"$tmpdir/routes.4" ;;
  prefix6) printf '2001:db8:2::/64 dev br-guest\n' >>"$tmpdir/routes.6" ;;
  dns) printf 'nameserver 10.0.0.2\n' >"$DNS_AUTO_RESOLVFILE" ;;
  esac
  net_refresh
  assert_eq $'dns\nnft' "$(cat "$events")" 'changed inputs refresh both policies'
  assert_true 'successful refresh stores fingerprint' test -s "$NET_FP_FILE"
  : >"$events"
  net_refresh
  assert_eq '' "$(cat "$events")" 'stored changed fingerprint skips renderers'
  ;;
 failure)
  rm -f "$NET_FP_FILE"
  dns_apply() { echo dns >>"$events"; return 1; }
  net_refresh || rc=$?
  assert_eq 1 "$rc" 'failed refresh reports failure'
  assert_false 'failed refresh stores no fingerprint' test -e "$NET_FP_FILE"
  assert_eq $'dns\nnft\ndns\nnft' "$(cat "$events")" 'DNS failure still refreshes nft'
  ;;
 snapshot)
  rm -f "$NET_FP_FILE"
  dns_apply() { printf 'nameserver 10.0.0.3\n' >"$DNS_AUTO_RESOLVFILE"; }
  net_refresh
  dns_apply() { echo dns >>"$events"; }
  : >"$events"
  net_refresh
  assert_eq $'dns\nnft' "$(cat "$events")" 'network change during refresh is not cached early'
  ;;
 esac
)

check_invalidation() (
 local scenario="$1"
 printf stale >"$NET_FP_FILE"
 settings_require() { return 0; }
 nft_render() { printf 'transaction\n' >"$1"; }
 nft() { return 0; }
 route_setup() { :; }
 route_cleanup() { :; }
 dns_render() { : >"$1"; }
 dns_confdirs() { :; }
 case "$scenario" in
 start | settings) policy_apply ;;
 stop) policy_cleanup ;;
 lists) service_ready() { return 0; }; nft_apply_if_ready ;;
 dns) dns_apply ;;
 nft_failure) settings_require() { return 1; }; nft_apply || : ;;
 dns_failure) settings_require() { return 1; }; dns_apply || : ;;
 esac
 assert_false "$scenario invalidates fingerprint" test -e "$NET_FP_FILE"
)

failed=0
for scenario in same table_missing prefix4 prefix6 dns failure snapshot; do
 if check_refresh "$scenario"; then pass "net refresh fingerprint: $scenario"; else failed=1; fi
done
for scenario in start stop settings lists dns nft_failure dns_failure; do
 if check_invalidation "$scenario"; then pass "net fingerprint invalidation: $scenario"; else failed=1; fi
done
exit "$failed"
