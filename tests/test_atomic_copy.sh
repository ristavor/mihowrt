#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
exec 3>&2
load_modules constants.sh helpers.sh validate.sh lists.sh subscription.sh service.sh

# Exercise the primitive in BusyBox ash, including partially written staging.
for outcome in success cp-failure mv-failure; do
 mkdir -p "$tmpdir/$outcome/source" "$tmpdir/$outcome/destination"
 printf 'new content\n' >"$tmpdir/$outcome/source/input"
 printf 'old content\n' >"$tmpdir/$outcome/destination/output"
 MIHOWRT_LIB_DIR="$MIHOWRT_LIB_DIR" ash -s -- "$tmpdir/$outcome" "$outcome" <<'ASH'
 . "$MIHOWRT_LIB_DIR/helpers.sh"
 src="$1/source/input"
 dst="$1/destination/output"
 outcome="$2"
 command -v atomic_copy >/dev/null || { echo 'FAIL: atomic_copy helper missing' >&2; exit 1; }
 cp() {
  [ "$2" = "$dst.new.$$" ] || exit 2
  [ "$(cat "$dst")" = 'old content' ] || exit 3
  if [ "$outcome" = cp-failure ]; then printf partial >"$2"; return 1; fi
  command cp "$@"
 }
 mv() {
  [ "$1" = -f ] && [ "$2" = "$dst.new.$$" ] && [ "$3" = "$dst" ] || exit 4
  [ "$outcome" != mv-failure ] || return 1
  command mv "$@"
 }
 rc=0
 atomic_copy "$src" "$dst" || rc=$?
 case "$outcome" in
 success) [ "$rc" = 0 ] && [ "$(cat "$dst")" = 'new content' ] || exit 5 ;;
 *) [ "$rc" = 1 ] && [ "$(cat "$dst")" = 'old content' ] || exit 6 ;;
 esac
 [ ! -e "$dst.new.$$" ] || exit 7
ASH
 pass "atomic_copy $outcome preserves atomic sibling publication"
done

for consumer in remote metadata database list; do
 for outcome in success cp-failure mv-failure; do
 (
  setup_runtime_paths "$tmpdir/$consumer-$outcome"
  target="$PKG_PERSIST_DIR/output"
  : >"$tmpdir/warnings"
  warn() { echo "$*" >>"$tmpdir/warnings"; }
  case "$consumer" in
  remote)
   POLICY_CACHE_DIR="$PKG_PERSIST_DIR/cache"
   mkdir -p "$POLICY_CACHE_DIR"
   target="$(lists_cache_file https://lists.example/test)"
   lists_urls() { echo https://lists.example/test; }
   lists_cache_gc() { :; }
   http_fetch() { echo 9.9.9.9 >"$2"; }
   publish() { lists_update_remote 1; }
   expected=9.9.9.9
   ;;
  metadata)
   SUBSCRIPTION_META_FILE="$target"
   settings_load() { SUBSCRIPTION_URL=https://subscription.example/config; BYPASS_SUBSCRIPTION_DNS=0; }
   http_fetch() { echo 'proxies: []' >"$2"; : >"$6"; }
   subscription_is_clash() { return 0; }
   subscription_metadata_from_headers() { echo '{"profile_title":"new"}'; }
   config_api_wait() { :; }
   with_lock() { "$@"; }
   config_install() { echo '{"action":"hot_reloaded"}'; }
   lists_urls() { echo https://lists.example/test; }
   lists_update_remote() { echo refresh >>"$PKG_TMP_DIR/events"; echo unchanged; }
   cron_update() { echo cron >>"$PKG_TMP_DIR/events"; }
   publish() { subscription_update https://new.example/config; }
   expected='{"profile_title":"new"}'
   ;;
  database)
   target="$PKG_PERSIST_DIR/cache.db"
   CACHE_DB_TMPFS="$PKG_TMP_DIR/cache.db"
   echo database >"$CACHE_DB_TMPFS"
   publish() { cache_db_persist; }
   expected=database
   ;;
  list)
   DST_LIST_FILE="$target"
   upload="/tmp/mihowrt-policy-list.atomic.$$"
   trap 'rm -f "$upload"' EXIT
   echo 9.9.9.9 >"$upload"
   settings_load() { :; }
   cron_update() { :; }
   publish() { lists_install "$upload" - - -; }
   expected=9.9.9.9
   ;;
  esac
  echo old >"$target"
  cp() {
   if [ "${2:-}" = "$target.new.$$" ]; then
    assert_eq old "$(cat "$target")" "$consumer keeps target during copy"
    if [ "$outcome" = cp-failure ]; then echo partial >"$2"; return 1; fi
   fi
   command cp "$@"
  }
  mv() {
   if [ "${3:-}" = "$target" ]; then
    assert_eq "$target.new.$$" "$2" "$consumer renames a sibling stage" 2>&3
    [ "$outcome" != mv-failure ] || return 1
   fi
   command mv "$@"
  }
  rc=0
  publish >"$tmpdir/out" 2>"$tmpdir/err" || rc=$?
  if [ "$outcome" = success ]; then
   assert_eq 0 "$rc" "$consumer publishes successfully"
   assert_eq "$expected" "$(cat "$target")" "$consumer replaces content"
  else
   if [ "$consumer" = metadata ]; then
    assert_eq 0 "$rc" 'metadata failure does not fail the installed subscription'
    assert_eq "Cannot write $target" "$(cat "$tmpdir/warnings")" 'metadata failure warns'
   else
    assert_eq 1 "$rc" "$consumer propagates publish failure"
   fi
   assert_eq old "$(cat "$target")" "$consumer failure keeps old content"
   if [ "$consumer" = remote ]; then
    assert_eq 'Remote list cache write failed: lists.example' "$(cat "$tmpdir/warnings")" 'remote cache write failure warns with host'
   fi
  fi
  assert_eq '' "$(find "${target%/*}" -name '*.new.*' -print)" "$consumer removes staging files"
  if [ "$consumer" = metadata ]; then
   assert_eq https://new.example/config "$(uci_get subscription_url)" 'installed subscription saves the new URL'
   assert_true 'installed subscription advances update stamp' test -f "$PKG_STATE_DIR/subscription.stamp"
   assert_eq $'refresh\ncron' "$(cat "$PKG_TMP_DIR/events")" 'installed subscription refreshes lists and cron'
   assert_eq '{"action":"hot_reloaded"}' "$(cat "$tmpdir/out")" 'installed subscription returns result'
   assert_false 'metadata scratch removed' test -e "$PKG_TMP_DIR/subscription.json"
   assert_false 'subscription headers removed' test -e "$PKG_TMP_DIR/subscription.$$.headers"
  fi
 )
 pass "$consumer $outcome uses atomic_copy publication"
 done
done
