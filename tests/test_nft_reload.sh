#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
export RELOAD_TEST_DIR="$tmpdir"

failed=0
for scenario in same list setting source profile remote table_missing ipv6 prefix failure cleanup; do
 if ash -s "$scenario" <<'ASH'
set -e
. "$MIHOWRT_LIB_DIR/constants.sh"
. "$MIHOWRT_LIB_DIR/helpers.sh"
mihowrt_load_modules
scenario="$1"
test_root="$RELOAD_TEST_DIR/$scenario"
PKG_TMP_DIR="$test_root/tmp"
PKG_STATE_DIR="$test_root/run"
NFT_APPLIED_FILE="$PKG_TMP_DIR/nft.applied"
NET_FP_FILE="$PKG_STATE_DIR/net.fp"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
PROFILE_FILE="$test_root/profile"
POLICY_CACHE_DIR="$test_root/cache"
LIST_DIR="$test_root/lists"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
RUNTIME_CONFIG="$test_root/runtime.yaml"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR" "$POLICY_CACHE_DIR"
lists_ensure_files
printf 'mode direct-first\ndns redir-host\n' >"$PROFILE_FILE"
printf '1.1.1.1;443\n' >"$DST_LIST_FILE"
printf 'runtime\n' >"$RUNTIME_CONFIG"
settings_load
service_ready() { return 0; }
cron_update() { :; }
lists_update_remote() { :; }
route_setup() { echo route >>"$test_root/events"; }
dns_apply() { echo dns >>"$test_root/events"; }
mihomo_config_generate() { cp "$RUNTIME_CONFIG" "$2"; cp "$PROFILE_FILE" "$2.profile"; }
ip() { :; }
route_ipv6_enabled() { return 0; }
nft_active() { [ ! -e "$test_root/missing" ]; }
nft() {
 [ "$1" != delete ] || { touch "$test_root/missing"; return 0; }
 [ "$1" = -f ] || exit 91
 echo apply >>"$test_root/applies"
 [ ! -e "$test_root/failure" ]
}
# Keep the real renderer, recording whether the expensive pass ran.
eval "$(sed 's/^nft_render()/nft_render_real()/' "$MIHOWRT_LIB_DIR/nft.sh" | sed -n '/^nft_render_real()/,/^}/p')"
nft_render() { echo render >>"$test_root/renders"; nft_render_real "$@"; }
lists_apply - - - - >/dev/null
[ "$(wc -l <"$test_root/renders")" -eq 1 ]
case "$scenario" in
list) printf '8.8.8.8;443\n' >"$DST_LIST_FILE" ;;
setting) settings_load() { DISABLE_QUIC=0; } ;;
source) settings_load() { DST_LIST_SOURCE=own; } ;;
profile) printf 'has proxy-ips\nproxy-ip 8.8.8.8;443\n' >>"$PROFILE_FILE" ;;
remote)
 printf 'https://example.org/list\n' >"$DST_LIST_FILE"
 cache="$(lists_cache_file https://example.org/list)"
 printf '1.1.1.1;443\n' >"$cache"
 lists_apply - - - - >/dev/null
 : >"$test_root/renders"; echo render >"$test_root/renders"
 : >"$test_root/applies"; echo apply >"$test_root/applies"
 printf '8.8.8.8;443\n' >"$cache"
 ;;
table_missing) touch "$test_root/missing" ;;
ipv6) route_ipv6_enabled() { return 1; } ;;
prefix) ip() { [ "$*" != '-4 route show table main' ] || echo '203.0.113.0/24 dev br-test'; } ;;
failure) touch "$test_root/failure"; printf '8.8.8.8;443\n' >"$DST_LIST_FILE" ;;
cleanup) nft_cleanup; [ ! -e "$NFT_APPLIED_FILE.inputs" ] ;;
esac
rc=0
service_reload || rc=$?
if [ "$scenario" = same ]; then
 [ "$(wc -l <"$test_root/renders")" -eq 1 ] || { echo 'unchanged reload rendered the identical policy again' >&2; exit 1; }
 [ "$(wc -l <"$test_root/applies")" -eq 1 ]
else
 [ "$(wc -l <"$test_root/renders")" -eq 2 ] || { echo "$scenario did not re-render" >&2; exit 1; }
 case "$scenario" in
 source) : ;; # An input change can still render identical bytes.
 *) [ "$(wc -l <"$test_root/applies")" -eq 2 ] || { echo "$scenario did not apply" >&2; exit 1; } ;;
 esac
fi
if [ "$scenario" = failure ]; then
 [ "$rc" -eq 1 ]
 rm "$test_root/failure"
 service_reload
 [ "$(wc -l <"$test_root/applies")" -eq 3 ] || { echo 'failed transaction was cached' >&2; exit 1; }
else
 [ "$rc" -eq 0 ]
 [ "$(cat "$test_root/events")" = "$(printf 'route\ndns')" ] || { echo 'reload skipped route/DNS work' >&2; exit 1; }
fi
ASH
 then pass "nft reload input fingerprint: $scenario"; else failed=1; fi
done
exit "$failed"
