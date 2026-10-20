#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh migration.sh
OLD_DNS_BACKUP_FILE="$tmpdir/dns.backup"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
CRON_FILE="$tmpdir/crontab"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
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
assert_eq "6" "$(uci_get subscription_interval)" "manual interval kept"
assert_eq "4" "$(uci_get lists_interval)" "smallest list interval"
assert_eq "" "$(uci_get subscription_userinfo)" "old metadata options removed"
assert_eq "keep me" "$(cat "$CRON_FILE")" "old cron lines removed"
pass "options migrated"

before="$(cat "$FAKE_UCI_DB")"
migrate
assert_eq "$before" "$(cat "$FAKE_UCI_DB")" "migration idempotent"
pass "idempotent"

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
