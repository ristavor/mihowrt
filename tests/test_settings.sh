#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh

settings_load || fail "empty UCI must load"
assert_eq "direct-first" "$POLICY_MODE" "default policy mode"
assert_eq "br-lan" "$SOURCE_INTERFACES" "default source interface"
assert_eq "1:1:0:1:1" "$DNS_HIJACK:$DISABLE_QUIC:$NETBIRD_PROXY:$BYPASS_NTP:$BYPASS_SUBSCRIPTION_DNS" "default toggles"
assert_eq "24:0" "$SUBSCRIPTION_INTERVAL:$LISTS_INTERVAL" "default intervals (subscription auto = 24 h)"
assert_eq "113920" "$NETBIRD_MARK" "default NetBird mark"
pass "settings defaults"

expect_invalid() {
	local option="$1" value="$2"

	fake_uci_reset
	fake_uci_set "mihowrt.settings.$option" "$value"
	if settings_load 2>/dev/null; then
		fail "$option=$value must be rejected"
	fi
}

expect_invalid policy_mode foo
expect_invalid source_network_interfaces 'br;lan'
expect_invalid netbird_mark 0x08000000
expect_invalid netbird_mark 0x1BD01
expect_invalid subscription_url 'ftp://x'
expect_invalid subscription_interval abc
pass "settings rejects invalid values"

fake_uci_reset
fake_uci_set mihowrt.settings.policy_mode proxy-first
fake_uci_set mihowrt.settings.source_network_interfaces 'br-lan wg0'
fake_uci_set mihowrt.settings.bypass_ntp 0
settings_load || fail "valid settings must load"
assert_eq "proxy-first|br-lan wg0|0" "$POLICY_MODE|$SOURCE_INTERFACES|$BYPASS_NTP" "explicit values"
pass "settings explicit values"

fake_uci_reset
settings_ensure_generated || fail "generate must succeed"
secret="$(uci_get api_secret)"
minute="$(uci_get cron_minute)"
assert_eq 48 "${#secret}" "secret length"
if ! [[ "$minute" =~ ^[0-9]+$ ]] || (( minute > 59 )); then fail "minute out of range: $minute"; fi
settings_ensure_generated
assert_eq "$secret|$minute" "$(uci_get api_secret)|$(uci_get cron_minute)" "generated values stay stable"
fake_uci_set mihowrt.settings.api_secret 'keep-this-secret-01'
settings_ensure_generated
assert_eq "keep-this-secret-01" "$(uci_get api_secret)" "existing secret kept"
pass "settings generated values idempotent"

fake_uci_reset
fake_uci_set mihowrt.settings.api_secret 'bad"secret'
if settings_load 2>/dev/null; then fail "secret with quotes must be rejected"; fi
pass "api secret validated"

assert_true "compressed IPv6 with 7 groups" is_ipv6 1:2:3:4:5:6::7
assert_true "IPv6 loopback" is_ipv6 ::1
assert_false "too many groups" is_ipv6 1:2:3:4:5:6:7:8:9
pass "ipv6 validator"

# G: a failed write must not truncate root's crontab.
CRON_FILE="$tmpdir/crontab"
printf '0 3 * * * /root/backup.sh\n' >"$CRON_FILE"
grep() { return 2; }
cron_sync "# m" 1 "17 * * * * x" 2>/dev/null || true
unset -f grep
assert_file_contains "$CRON_FILE" "/root/backup.sh" "crontab kept on write error"
pass "cron sync safe on errors"

# F: a stale lock is removed only if it still belongs to the dead owner.
RUNTIME_LOCK_FILE="$tmpdir/lock"
ln -s 999999 "$RUNTIME_LOCK_FILE"
kill() { if [ "$1" = -0 ] && [ "$2" = 999999 ]; then ln -sfn $$ "$RUNTIME_LOCK_FILE.live"; mv -f "$RUNTIME_LOCK_FILE.live" "$RUNTIME_LOCK_FILE"; return 1; fi; command kill "$@"; }
RUNTIME_LOCK_TIMEOUT=1 lock_acquire 2>/dev/null || true
unset -f kill
assert_eq "$$" "$(readlink "$RUNTIME_LOCK_FILE")" "a lock taken meanwhile is not stolen"
rm -f "$RUNTIME_LOCK_FILE"
pass "stale lock removal re-checks owner"
