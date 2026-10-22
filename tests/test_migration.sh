#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh migration.sh
setup_runtime_paths "$tmpdir"
ROUTE_STATE_FILE="$PKG_STATE_DIR/route.state"

OLD_DNS_BACKUP_FILE="$tmpdir/dns.backup"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
DIRECT_SRC_LIST_FILE="$LIST_DIR/direct_src"
mkdir -p "$CLASH_DIR" "$LIST_DIR"

uci set 'dhcp.@dnsmasq[0].server=127.0.0.1#7874'
uci set 'dhcp.@dnsmasq[0].noresolv=1'
cat >"$OLD_DNS_BACKUP_FILE" <<'B'
ORIG_CACHESIZE=1000
ORIG_NORESOLV=
ORIG_RESOLVFILE=/tmp/resolv.conf.d/resolv.conf.auto
ORIG_SERVER=1.1.1.1 9.9.9.9
B
migrate_dns_uci
assert_eq "1.1.1.1 9.9.9.9" "$(uci get 'dhcp.@dnsmasq[0].server')" "servers restored"
if uci -q get 'dhcp.@dnsmasq[0].noresolv' >/dev/null; then fail "noresolv must be removed"; fi
[[ ! -e "$OLD_DNS_BACKUP_FILE" ]] || fail "backup deleted"
migrate_dns_uci
assert_eq "1.1.1.1 9.9.9.9" "$(uci get 'dhcp.@dnsmasq[0].server')" "second run is a no-op"
pass "dns backup restored once"

cat >"$CLASH_CONFIG" <<'Y'
secret: 'old-secret-1234'
dns:
  secret: nested-ignored
Y
fake_uci_set mihowrt.settings.subscription_interval_override 1
fake_uci_set mihowrt.settings.subscription_update_interval 6
fake_uci_set mihowrt.settings.subscription_userinfo 'upload=1'
printf 'https://x/list.txt | 12\nhttps://y/l.txt | 4\n' >"$DST_LIST_FILE"
printf '0 * * * * a # mihowrt subscription auto-update\nkeep me\n5 * * * * b # mihowrt policy remote auto-update\n' >"$CRON_FILE"
migrate
assert_eq "1" "$(uci_get subscription_auto_update)" "auto updates migrated"
assert_eq "" "$(uci_get subscription_interval)" "old interval removed"
assert_eq "4" "$(uci_get lists_interval)" "smallest list interval"
assert_eq "" "$(uci_get subscription_userinfo)" "old metadata options removed"
assert_eq "keep me" "$(cat "$CRON_FILE")" "old cron lines removed"
pass "options migrated"

before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" "migration idempotent"
pass "idempotent"

# 0.9.1 config: no Traffic flags. They get their backend defaults, once.
fake_uci_reset
fake_uci_set mihowrt.settings.source_network_interfaces br-lan
fake_uci_set mihowrt.settings.lists_interval 24
fake_uci_set mihowrt.settings.api_secret s3cret
fake_uci_set mihowrt.settings.cron_minute 7
fake_uci_set mihowrt.settings.subscription_url https://x.example/sub
fake_uci_set mihowrt.settings.subscription_auto_update 1
fake_uci_set mihowrt.settings.bypass_ntp 1
fake_uci_set mihowrt.settings.bypass_subscription_dns 1
migrate_settings
assert_eq 1 "$(uci_get dns_hijack)" "dns_hijack default written"
assert_eq 1 "$(uci_get disable_quic)" "disable_quic default written"
assert_eq 0 "$(uci_get netbird_proxy)" "netbird_proxy default written"
assert_eq "s3cret" "$(uci_get api_secret)" "existing keys kept"
assert_eq "$(printf 'api_secret\nbypass_ntp\nbypass_subscription_dns\ncron_minute\ndisable_quic\ndns_hijack\nlists_interval\nnetbird_proxy\nsource_network_interfaces\nsubscription_auto_update\nsubscription_url')" \
 "$(uci -X show mihowrt.settings 2>/dev/null | sed -n 's/^mihowrt\.settings\.\([a-z_]*\)=.*/\1/p' | sort)" "only the missing flags added"
before="$(cat "$FAKE_UCI_DB")"
migrate_settings
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" "second migrate_settings is a no-op"
fake_uci_set mihowrt.settings.dns_hijack 0
fake_uci_set mihowrt.settings.disable_quic 0
fake_uci_set mihowrt.settings.netbird_proxy 1
migrate_settings
assert_eq "0 0 1" "$(uci_get dns_hijack) $(uci_get disable_quic) $(uci_get netbird_proxy)" "existing flag values never overwritten"
pass "0.9.1 config gets flag defaults"

fake_uci_reset
printf "secret: 'old-secret-1234'\n" >"$CLASH_CONFIG"
migrate_settings
[ "$(uci_get api_secret)" != "old-secret-1234" ] || fail "migration must not reuse the YAML secret (read ACL can read the YAML)"
pass "secret not reused from YAML"

cat >"$SRC_LIST_FILE" <<'L'
# One IPv4 or CIDR per line. Optional :port, :port-port, or :port,port.
# Use :port without IP to match any IPv4 client.
# Example:
# 192.168.1.10
# 192.168.1.32/27
192.168.1.151
# my note
L
printf '# Example:\n1.1.1.1\n' >"$DST_LIST_FILE"
migrate_list_headers
assert_eq "$(printf '192.168.1.151\n# my note')" "$(cat "$SRC_LIST_FILE")" "0.7 header removed, user lines kept"
assert_eq "$(printf '# Example:\n1.1.1.1')" "$(cat "$DST_LIST_FILE")" "files without the 0.7 header untouched"
migrate_list_headers
assert_eq "$(printf '192.168.1.151\n# my note')" "$(cat "$SRC_LIST_FILE")" "header removal idempotent"
pass "0.7 list headers removed"

for old in 0 6 ''; do
 fake_uci_reset
 fake_uci_set mihowrt.settings.policy_mode direct-first
 fake_uci_set mihowrt.settings.subscription_interval "$old"
 migrate_settings
 expected=1; [ "$old" != 0 ] || expected=0
 assert_eq "$expected" "$(uci_get subscription_auto_update)" "migrate interval $old"
 assert_false "legacy interval deleted" uci -q get mihowrt.settings.subscription_interval
 assert_false "manual mode deleted" uci -q get mihowrt.settings.policy_mode
done
pass "0.9 migration removes manual mode and interval"

# A full migrate must read the hours before removing the suffix.
fake_uci_reset
printf '1.1.1.1 | 12\nhttps://x.example/l.txt | 6\n# c | x\n' >"$DST_LIST_FILE"
printf '192.168.1.2 | 08\n  # note | 12\n' >"$DIRECT_SRC_LIST_FILE"
migrate
assert_eq 6 "$(uci_get lists_interval)" "legacy hours read before suffix rewrite"
assert_eq "$(printf '1.1.1.1\nhttps://x.example/l.txt\n# c | x')" "$(cat "$DST_LIST_FILE")" "suffix stripped, comments kept"
assert_eq "$(printf '192.168.1.2\n  # note | 12')" "$(cat "$DIRECT_SRC_LIST_FILE")" "fourth own list migrated"
pass "migrate list suffix"

calls="$tmpdir/ip.calls"
ip() {
 echo "ip $*" >>"$calls"
 case "$*" in
 '-4 rule show') echo '10001: from all fwmark 0x1000/0x1000 lookup 201' ;;
 *'rule del'*) return 1 ;;
 esac
 return 0
}
printf 'ROUTE_TABLE_ID=201\nROUTE_RULE_PRIORITY=10001\n' >"$ROUTE_STATE_FILE"
migrate
assert_file_contains "$calls" 'ip -4 rule del fwmark 0x1000/0x1000 lookup 201 priority 10001' "0.7 rule removed"
assert_file_contains "$calls" 'ip -4 route flush table 201' "0.7 table flushed"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "legacy route state removed"
pass "migrate 0.7 routes"
: >"$calls"
printf 'TABLE=202\nPRIORITY=10002\n' >"$ROUTE_STATE_FILE"
migrate_route_07
assert_file_contains "$ROUTE_STATE_FILE" 'TABLE=202' "current route state preserved"
assert_file_not_contains "$calls" 'flush table 202' "current table preserved"
pass "migration preserves current route state"

: >"$calls"
rm -f "$ROUTE_STATE_FILE"
migrate_route_07
assert_file_contains "$calls" 'ip -4 rule del fwmark 0x1000/0x1000 lookup 201 priority 10001' "legacy mark found without state"
assert_file_contains "$calls" 'ip -4 route flush table 201' "orphan legacy table flushed"
pass "migration finds orphan 0.7 rules"

ip() {
 echo "ip $*" >>"$calls"
 case "$*" in *'rule del'*) return 1 ;; esac
 return 0
}
: >"$calls"
printf 'ROUTE_TABLE_ID=00201\nROUTE_RULE_PRIORITY=010001\n' >"$ROUTE_STATE_FILE"
migrate_route_07
assert_file_contains "$calls" 'ip -4 rule del fwmark 0x00001000/0x00001000 lookup 201 priority 10001' "legacy state normalized without listing"
assert_file_contains "$calls" 'ip -4 route flush table 201' "legacy state table flushed"
[[ ! -e "$ROUTE_STATE_FILE" ]] || fail "legacy state removed without listing"
: >"$calls"
migrate_route_07
assert_file_not_contains "$calls" 'rule del' "second migration deletes nothing"
assert_file_not_contains "$calls" 'route flush' "second migration flushes nothing"
pass "migration uses legacy state and is idempotent"

ip() {
 echo "ip $*" >>"$calls"
 case "$*" in
 *'rule show')
  printf '%s\n' \
   '10001: from all fwmark 0x1000/0x1000 lookup 254' \
   '10002: from all fwmark 0x1000/0x1000 lookup main' \
   '10003: from all fwmark 0x1000/0x1000 lookup 199' \
   '10004: from all fwmark 0x1000/0x1000 lookup 253' \
   '10005: from all fwmark 0x1000/0x1000 lookup 200' \
   '10006: from all fwmark 0x1000/0x1000 lookup 252'
  ;;
 *'rule del'*) return 1 ;;
 esac
 return 0
}
: >"$calls"
migrate_route_07
for table in 254 main 199 253; do
 assert_file_not_contains "$calls" "lookup $table priority" "foreign table $table rule left alone"
 assert_file_not_contains "$calls" "flush table $table" "foreign table $table not flushed"
done
for table in 200 252; do
 assert_file_contains "$calls" "lookup $table priority" "old auto range boundary $table rule removed"
 assert_file_contains "$calls" "flush table $table" "old auto range boundary $table flushed"
done
pass "migration listing cleanup restricted to old auto range"

ip() {
 echo "ip $*" >>"$calls"
 case "$*" in *'rule del'*) return 1 ;; esac
 return 0
}
for table in 254 main 199 253; do
 : >"$calls"
 printf 'ROUTE_TABLE_ID=%s\nROUTE_RULE_PRIORITY=10001\n' "$table" >"$ROUTE_STATE_FILE"
 migrate_route_07
 assert_file_not_contains "$calls" 'rule del' "foreign state table $table rule left alone"
 assert_file_not_contains "$calls" 'route flush' "foreign state table $table not flushed"
 [[ -e "$ROUTE_STATE_FILE" ]] || fail "foreign state table $table preserved"
done
pass "migration state cleanup restricted to old auto range"

printf '1.1.1.1\n# c | 12\n' >"$DST_LIST_FILE"
touch -d '2024-01-01 00:00:00' "$DST_LIST_FILE"
before_mtime="$(stat -c %Y "$DST_LIST_FILE")"
migrate_list_suffix
assert_eq "$before_mtime" "$(stat -c %Y "$DST_LIST_FILE")" "unchanged list mtime preserved"
pass "suffix migration skips unchanged files"

printf '1.1.1.1 | 12\n' >"$DIRECT_SRC_LIST_FILE"
chmod 0600 "$DIRECT_SRC_LIST_FILE"
migrate_list_suffix
assert_eq '1.1.1.1' "$(cat "$DIRECT_SRC_LIST_FILE")" "private list suffix stripped"
assert_eq 600 "$(stat -c %a "$DIRECT_SRC_LIST_FILE")" "private list mode preserved"
pass "suffix migration preserves file mode"

# Remove the old symlink itself, never open or write through its target.
ln -s 12345 "$PKG_STATE_DIR/runtime.lock"
migrate
assert_false "legacy symlink removed" test -L "$PKG_STATE_DIR/runtime.lock"
assert_false "legacy relative target never created" test -e "$PKG_STATE_DIR/12345"
printf untouched >"$tmpdir/old-lock-target"
ln -s "$tmpdir/old-lock-target" "$PKG_STATE_DIR/runtime.lock"
migrate
assert_false "legacy absolute symlink removed" test -L "$PKG_STATE_DIR/runtime.lock"
assert_eq untouched "$(cat "$tmpdir/old-lock-target")" "legacy target untouched"
pass "migrate removes old lock without following it"
