#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
export READY_TEST_DIR="$tmpdir"

# Exercise the actual BusyBox runtime lock; readiness changes while waiting
# for it are represented by a different result once LOCK_DEPTH is positive.
failed=0
for operation in helper lists_apply lists_refresh subscription_update auto_update config_profile_apply; do
 for readiness in ready stopped; do
  if ash -s "$operation" "$readiness" <<'ASH'
set -eu
for module in constants helpers validate mihomo-config lists nft config subscription service; do
 . "$MIHOWRT_LIB_DIR/$module.sh"
done
operation="$1"; readiness="$2"
PKG_TMP_DIR="$READY_TEST_DIR/tmp"
PKG_STATE_DIR="$READY_TEST_DIR/run"
PROFILE_FILE="$PKG_TMP_DIR/profile"
SUBSCRIPTION_META_FILE="$PKG_TMP_DIR/subscription.json"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/runtime.flock"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR"
events="$READY_TEST_DIR/events"
: >"$events"
settings_load() { LISTS_INTERVAL=1; SUBSCRIPTION_URL=https://sub.example/config; BYPASS_SUBSCRIPTION_DNS=0; DNS_MODE=fake-ip; }
service_ready() {
 if [ "${LOCK_DEPTH:-0}" -gt 0 ]; then
  echo checked-under-lock >>"$events"
  [ "$readiness" = ready ]
 else
  return 0
 fi
}
nft_apply() {
 if busybox flock -n "$RUNTIME_LOCK_FILE" true; then
  echo 'nft_apply without runtime lock' >&2
  return 1
 fi
 echo apply >>"$events"
}
lists_install() { echo 0; }
lists_update_remote() { echo changed; }
lists_urls() { echo https://lists.example/list; }
subscription_due() { return 1; }
http_fetch() { printf 'proxies: []\n' >"$2"; }
config_api_wait() { :; }
config_install() { echo '{"action":"saved"}'; }
subscription_metadata_from_headers() { echo '{}'; }
cron_update() { :; }
policy_apply() { nft_apply; }
printf 'dns fake-ip\n' >"$PKG_TMP_DIR/old-profile"
printf 'dns redir-host\n' >"$PROFILE_FILE"
rc=0
case "$operation" in
helper)
 command -v nft_apply_if_ready >/dev/null || { echo 'missing nft_apply_if_ready' >&2; exit 1; }
 with_lock nft_apply_if_ready || rc=$?
 ;;
lists_apply) lists_apply - - - - >/dev/null || rc=$? ;;
lists_refresh) lists_refresh >/dev/null || rc=$? ;;
subscription_update) subscription_update >/dev/null || rc=$? ;;
auto_update) auto_update >/dev/null || rc=$? ;;
config_profile_apply) config_locked config_profile_apply "$PKG_TMP_DIR/old-profile" >/dev/null || rc=$? ;;
esac
if ! grep -q checked-under-lock "$events"; then
 echo "$operation: readiness was not checked inside the runtime lock" >&2
 exit 1
fi
if [ "$readiness" = ready ]; then
 [ "$rc" = 0 ] && grep -q '^apply$' "$events" || { echo "$operation: ready service was not applied" >&2; exit 1; }
else
 if grep -q '^apply$' "$events"; then
  echo "$operation: stopped service was applied" >&2
  exit 1
 fi
fi
ASH
  then pass "$operation checks $readiness service inside runtime lock"
  else failed=1
  fi
 done
done
exit "$failed"
