#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"; rm -f /tmp/mihowrt-policy-list.test-provider-"$$".*' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh fetch.sh subscription.sh lists.sh nft.sh config.sh service.sh
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
FETCH_HDR="$tmpdir/headers"
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
: >"$tmpdir/events"
sed -i 's/whitelist/blacklist/' "$tmpdir/download"
rm "$PKG_STATE_DIR/subscription.stamp"
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
pass "subscription cron transitions, provider list refresh, broken extensions and four-list installation"
