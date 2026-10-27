#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"; rm -f /tmp/mihowrt-policy-list.test-provider-"$$".*' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh fetch.sh subscription.sh lists.sh nft.sh route.sh config.sh service.sh
printf '\357\273\277"proxies": []\n' >"$tmpdir/keys"
(
 awk() { busybox awk "$@"; }
 assert_true 'subscription_is_clash accepts bom quoted key' subscription_is_clash "$tmpdir/keys"
)
pass 'subscription bom quoted key'
API_SECRET=""
PKG_TMP_DIR="$tmpdir/tmp"
PKG_STATE_DIR="$tmpdir/run"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
CLASH_CONFIG_BACKUP="$CLASH_CONFIG.bak"
RUNTIME_CONFIG="$tmpdir/runtime.yaml"
PROFILE_FILE="$RUNTIME_CONFIG.profile"
CONFIG_OK_FILE="$PKG_STATE_DIR/config.ok"
CONFIG_ERR_FILE="$PKG_STATE_DIR/config.err"
RUNTIME_LOCK_FILE="$PKG_STATE_DIR/lock"
NFT_APPLIED_FILE="$tmpdir/nft.applied"
SUBSCRIPTION_META_FILE="$tmpdir/subscription.json"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lists"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
POLICY_CACHE_DIR="$tmpdir/cache"
mkdir -p "$PKG_TMP_DIR" "$PKG_STATE_DIR" "$CLASH_DIR"
lists_ensure_files
CLASH_BIN="$tmpdir/core"
printf '#!/bin/sh\nexit 0\n' >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
fake_uci_set mihowrt.settings.subscription_url https://p.example/sub
fake_uci_set mihowrt.settings.bypass_subscription_dns 0
fake_uci_set mihowrt.settings.subscription_auto_update 1
service_running() { return 0; }
service_ready() { return 0; }
api_alive() { return 0; }
api_reload() { echo reload >>"$tmpdir/events"; }
nft_active() { return 0; }
nft() { echo "nft:$*" >>"$tmpdir/events"; }
policy_apply() { echo "policy:$POLICY_MODE" >>"$tmpdir/events"; nft_apply; }
dns_restart_dnsmasq() { echo dns-restart >>"$tmpdir/events"; }
http_fetch() {
 FETCH_HDR="$6"
 assert_eq "$PKG_TMP_DIR/subscription.$$.headers" "$FETCH_HDR" "subscription requests explicit headers"
 assert_eq 0 "${LOCK_DEPTH:-0}" "download outside lock"
 assert_false "download leaves runtime lock free" lock_busy
 cp "$tmpdir/download" "$2"
 printf 'HTTP/1.1 200 OK\r\n%s\r\n' "$headers" >"$FETCH_HDR"
}
headers='profile-update-interval: 12'
printf 'proxies: []\ndns:\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: whitelist\n' >"$tmpdir/download"
# First download: metadata must be reloaded before cron is computed.
subscription_update >/dev/null
assert_file_contains "$CRON_FILE" '/usr/bin/mihowrt auto-update' "first provider header enables cron"
assert_eq 12 "$(settings_subscription_interval)" "first header effective"
subscription_json | jq -e '.auto_update and .effective_interval == 12 and (has("interval") | not)' >/dev/null || fail "new subscription JSON fields"
# C7: the Subscription page reads the backup flag here, not from status-json.
had_backup=0
[ ! -f "$CLASH_CONFIG_BACKUP" ] || { had_backup=1; mv "$CLASH_CONFIG_BACKUP" "$tmpdir/backup.c7"; }
assert_eq false "$(subscription_json | jq -c '.config_backup')" "no backup in subscription JSON"
printf 'proxies: []\n' >"$CLASH_CONFIG_BACKUP"
assert_eq true "$(subscription_json | jq -c '.config_backup')" "backup in subscription JSON"
mv "$SUBSCRIPTION_META_FILE" "$SUBSCRIPTION_META_FILE.c7"
printf '{"config_backup":true}' >"$SUBSCRIPTION_META_FILE"
rm -f "$CLASH_CONFIG_BACKUP"
assert_eq false "$(subscription_json | jq -c '.config_backup')" "provider metadata cannot claim a backup"
mv "$SUBSCRIPTION_META_FILE.c7" "$SUBSCRIPTION_META_FILE"
[ "$had_backup" = 0 ] || mv "$tmpdir/backup.c7" "$CLASH_CONFIG_BACKUP"
pass 'subscription JSON config_backup'
: >"$tmpdir/events"
sed -i 's/whitelist/blacklist/' "$tmpdir/download"
touch -d '25 hours ago' "$PKG_STATE_DIR/subscription.stamp"
auto_update >/dev/null
assert_eq proxy-first "$(profile_get mode)" "cron whitelist to blacklist derives new mode"
assert_file_contains "$tmpdir/events" 'policy:proxy-first' "cron reapplies policy"
assert_eq 1 "$(grep -c '^nft:-f ' "$tmpdir/events")" "cron mode flip reapplies nft once"
assert_eq 1 "$(grep -c '^reload$' "$tmpdir/events")" "cron hot reloads without service restart"
# New provider URL is fetched unlocked, then nft is applied under the lock.
printf 'x-mihowrt:\n  proxy-ips:\n    - https://p.example/list.txt\n' >>"$tmpdir/download"
lists_update_remote() {
 assert_eq 0 "${LOCK_DEPTH:-0}" "remote list fetch outside lock"
 assert_false "remote list fetch leaves runtime lock free" lock_busy
 echo fetched >>"$tmpdir/events"
 echo changed
}
nft_apply() {
 assert_true "nft apply owns runtime lock" test "${LOCK_DEPTH:-0}" -gt 0
 assert_eq "$$" "$(cat "$RUNTIME_LOCK_FILE.owner")" "nft apply owner metadata"
 echo nft-ready >>"$tmpdir/events"
}
: >"$tmpdir/events"
subscription_update >/dev/null
assert_file_contains "$tmpdir/events" fetched "new provider list fetched"
assert_eq nft-ready "$(tail -n1 "$tmpdir/events")" "nft reapplied after list fetch"
# A broken extension is ignored by the real generator/install path.
printf 'proxies: []\nx-mihowrt:\n  disable-quic: maybe\n  unknown: true\n  direct-ips: [1.2.3.4]\n' >"$tmpdir/download"
subscription_update >/dev/null
cmp -s "$CLASH_CONFIG" "$tmpdir/download" || fail "broken extension still installs byte-identically"
assert_file_contains "$PROFILE_FILE" 'ignored disable-quic' "bad extension ignored"
# Without a period the subscription must not acquire a cron schedule.
headers=''
subscription_update >/dev/null
assert_file_not_contains "$CRON_FILE" '/usr/bin/mihowrt auto-update' "absent header removes schedule"
# Exercise actual four-file installation, retaining the user's fourth list.
for i in 1 2 3 4; do printf '192.0.2.%s\n' "$i" >"/tmp/mihowrt-policy-list.test-provider-$$.$i"; done
service_ready() { return 1; }
lists_apply /tmp/mihowrt-policy-list.test-provider-"$$".{1,2,3,4} >/dev/null
assert_eq 192.0.2.4 "$(cat "$DIRECT_SRC_LIST_FILE")" "fourth list installed"
# Reboot removes the tmpfs stamp, but persistent metadata retains an update time.
rm -f "$PKG_STATE_DIR/subscription.stamp"
touch -d '1 hour ago' "$SUBSCRIPTION_META_FILE"
meta_mtime="$(date -r "$SUBSCRIPTION_META_FILE" +%s)"
assert_eq "$meta_mtime" "$(subscription_json | jq -r '.last_update')" "json uses meta mtime"
SUBSCRIPTION_INTERVAL=24
assert_false "due uses meta: one hour old is not due" subscription_due
touch -d '25 hours ago' "$SUBSCRIPTION_META_FILE"
assert_true "due uses meta: 25 hours old is due" subscription_due
# A newer tmpfs stamp takes precedence over unchanged persistent metadata.
touch -d '1 hour ago' "$PKG_STATE_DIR/subscription.stamp"
stamp_mtime="$(date -r "$PKG_STATE_DIR/subscription.stamp" +%s)"
assert_eq "$stamp_mtime" "$(subscription_json | jq -r '.last_update')" "stamp wins"
assert_false "stamp wins for due" subscription_due
assert_eq "$PKG_STATE_DIR/subscription.stamp" "$(subscription_stamp_file)" "stamp path wins"
rm "$PKG_STATE_DIR/subscription.stamp"
assert_eq "$SUBSCRIPTION_META_FILE" "$(subscription_stamp_file)" "metadata path fallback"
rm "$SUBSCRIPTION_META_FILE"
assert_false "no stamp or metadata returns failure" subscription_stamp_file
assert_eq "" "$(subscription_stamp_file || true)" "no stamp or metadata prints nothing"
assert_eq null "$(subscription_json | jq -r '.last_update')" "no timestamp remains null"
assert_true "no timestamp is due" subscription_due
pass "subscription cron transitions, provider list refresh, broken extensions, four-list installation and reboot timestamps"
