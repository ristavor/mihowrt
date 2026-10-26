#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh migration.sh
setup_runtime_paths "$tmpdir"
RC_D_DIR="$tmpdir/rc.d"
mkdir -p "$RC_D_DIR"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
ROUTE_STATE_FILE="$PKG_STATE_DIR/route.state"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
mkdir -p "$CLASH_DIR" "$LIST_DIR"
# Observe the retained generation boundary without generating random settings.
settings_ensure_generated() {
 if [ -n "${expected_secret:-}" ]; then
  assert_eq "$expected_secret" "$(cat "$API_SECRET_FILE")" 'secret migrated before generation'
  assert_false 'UCI secret deleted before generation' uci -q get mihowrt.settings.api_secret
 fi
 echo generated >>"$tmpdir/generated.calls"
}
uci() {
 case " $* " in *' commit '*) echo commit >>"$tmpdir/commit.calls" ;; esac
 command uci "$@"
}

migrate
assert_eq '1:1:0:1:1' "$(uci_get dns_hijack):$(uci_get disable_quic):$(uci_get netbird_proxy):$(uci_get bypass_ntp):$(uci_get bypass_subscription_dns)" 'flags written when empty'
assert_eq 0 "$(uci_get lists_interval)" 'lists_interval empty becomes 0'
assert_eq commit "$(cat "$tmpdir/commit.calls")" 'migrate commits retained defaults'
assert_eq generated "$(cat "$tmpdir/generated.calls")" 'migrate ensures generated settings'
pass 'flags written when empty; lists_interval empty becomes 0'

fake_uci_set mihowrt.settings.dns_hijack 0
fake_uci_set mihowrt.settings.disable_quic 0
fake_uci_set mihowrt.settings.netbird_proxy 1
fake_uci_set mihowrt.settings.bypass_ntp 0
fake_uci_set mihowrt.settings.bypass_subscription_dns 0
fake_uci_set mihowrt.settings.lists_interval 24
before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" 'existing Traffic flags and lists_interval kept'
fake_uci_set mihowrt.settings.lists_interval 0
migrate
assert_eq 0 "$(uci_get lists_interval)" 'existing disabled lists_interval kept'
pass 'existing flags and lists_interval kept'

# Remove the old symlink itself, never open or write through its target.
ln -s 12345 "$PKG_STATE_DIR/runtime.lock"
migrate
assert_false 'legacy symlink removed' test -L "$PKG_STATE_DIR/runtime.lock"
assert_false 'legacy relative target never created' test -e "$PKG_STATE_DIR/12345"
printf untouched >"$tmpdir/old-lock-target"
ln -s "$tmpdir/old-lock-target" "$PKG_STATE_DIR/runtime.lock"
migrate
assert_false 'legacy absolute symlink removed' test -L "$PKG_STATE_DIR/runtime.lock"
assert_eq untouched "$(cat "$tmpdir/old-lock-target")" 'legacy target untouched'
pass 'runtime.lock removed without following it'

echo 'proxy-ip http://10.0.0.1/old' >"$PROFILE_FILE"
migrate
assert_false 'profile from an older version removed' test -e "$PROFILE_FILE"
pass 'migrate drops the old provider profile'

touch "$CLASH_DIR/mihomo.sock"
migrate
assert_false 'old Mihomo socket removed' test -e "$CLASH_DIR/mihomo.sock"
pass 'migrate removes old Mihomo socket'

# polish: removed migrations
removed_count="$(grep -rEc 'migrate_(dns_uci|route_07|list_suffix|cron|list_headers)|OLD_DNS_BACKUP_FILE|OLD_SUBSCRIPTION_OPTIONS|dns.backup' "$ROOT_DIR/rootfs" | awk -F: '{ n += $NF } END { print n + 0 }' || true)"
assert_eq 0 "$removed_count" 'removed migrations'
pass 'removed migrations'

# The migration preserves the controller credential while retiring the UCI copy.
fake_uci_set mihowrt.settings.api_secret abcdefgh123
expected_secret=abcdefgh123
migrate
assert_eq abcdefgh123 "$(cat "$API_SECRET_FILE")" 'migrate keeps value'
assert_eq 600 "$(stat -c %a "$API_SECRET_FILE")" 'migrated file mode'
assert_false 'migrate removes UCI secret' uci -q get mihowrt.settings.api_secret
pass 'migrate keeps value'

printf '%s\n' xxxxxxxx >"$API_SECRET_FILE"
fake_uci_set mihowrt.settings.api_secret yyyyyyyy
expected_secret=xxxxxxxx
migrate
assert_eq xxxxxxxx "$(cat "$API_SECRET_FILE")" 'migrate keeps existing file'
assert_false 'migrate removes stale UCI secret' uci -q get mihowrt.settings.api_secret
migrate
assert_eq xxxxxxxx "$(cat "$API_SECRET_FILE")" 'secret migration is idempotent'
pass 'migrate keeps existing file'

# Remove only the retired boot hook, not the main service or its target.
printf untouched >"$tmpdir/retired-init"
ln -s "$tmpdir/retired-init" "$RC_D_DIR/S20mihowrt-recover"
ln -s "$tmpdir/retired-init" "$RC_D_DIR/S21mihowrt"
migrate
assert_false 'retired boot link removed' test -L "$RC_D_DIR/S20mihowrt-recover"
assert_true 'main service link kept' test -L "$RC_D_DIR/S21mihowrt"
assert_eq untouched "$(cat "$tmpdir/retired-init")" 'retired init target untouched'
migrate
assert_true 'main service link kept after repeated migration' test -L "$RC_D_DIR/S21mihowrt"
pass 'migrate removes recover link'
