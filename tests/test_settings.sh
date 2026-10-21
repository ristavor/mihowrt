#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh
setup_runtime_paths "$tmpdir"


# Run numeric regressions in ash, where leading zeros otherwise mean octal.
ash -c '
 . "$MIHOWRT_LIB_DIR/validate.sh"
 for pair in 0:0 000:0 08:8 0113920:113920 24:24; do
  actual="$(uint_norm "${pair%:*}")" || exit 1
  [ "$actual" = "${pair#*:}" ] || exit 1
 done
' || fail "uint_norm strips leading zeros in ash"
pass "uint_norm decimal normalization"

fake_uci_set mihowrt.settings.lists_interval 08
fake_uci_set mihowrt.settings.netbird_mark 0113920
fake_uci_set mihowrt.settings.cron_minute 07
ash -c '
 for module in constants helpers validate settings mihomo-config; do
  . "$MIHOWRT_LIB_DIR/$module.sh"
 done
 PROFILE_FILE="$1/profile"
 CLASH_CONFIG="$1/source.yaml"
 settings_load || exit 1
 [ "$LISTS_INTERVAL:$NETBIRD_MARK:$CRON_MINUTE" = "8:113920:7" ]
' ash "$tmpdir" || fail "leading zeros in UCI load as decimal in ash"
settings_load || fail "leading-zero settings must load"
assert_eq '8:113920:7' "$LISTS_INTERVAL:$NETBIRD_MARK:$CRON_MINUTE" "normalized UCI settings"
assert_eq 1 "$SETTINGS_LOADED" "successful load sets guard"
fake_uci_set mihowrt.settings.lists_interval 24
settings_require
assert_eq 8 "$LISTS_INTERVAL" "require preserves loaded settings"
settings_load
assert_eq 24 "$LISTS_INTERVAL" "explicit load refreshes settings"
fake_uci_reset
unset SETTINGS_LOADED
settings_require
assert_eq 0 "$LISTS_INTERVAL" "require loads when guard is absent"
pass "settings normalized and lazy loaded without suppressing refresh"


settings_load || fail "empty UCI must load"
assert_eq "proxy-first" "$POLICY_MODE" "default policy mode"
assert_eq redir-host "$DNS_MODE" "no YAML defaults to redir-host"
assert_eq "br-lan" "$SOURCE_INTERFACES" "default source interface"
assert_eq "1:1:0:1:1" "$DNS_HIJACK:$DISABLE_QUIC:$NETBIRD_PROXY:$BYPASS_NTP:$BYPASS_SUBSCRIPTION_DNS" "default toggles"
assert_eq "0:0" "$SUBSCRIPTION_INTERVAL:$LISTS_INTERVAL" "default intervals (no provider period)"
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

expect_invalid source_network_interfaces 'br;lan'
expect_invalid netbird_mark 0x08000000
expect_invalid netbird_mark 0x1BD01
expect_invalid subscription_url 'ftp://x'
expect_invalid lists_interval abc
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

fake_uci_reset
printf 'mode direct-first\ndns fake-ip\nset disable_quic 0\nset dns_hijack 0\n' >"$PROFILE_FILE"
fake_uci_set mihowrt.settings.disable_quic 1
fake_uci_set mihowrt.settings.dns_hijack 1
fake_uci_set mihowrt.settings.policy_mode proxy-first
settings_load
assert_eq '0:0:direct-first' "$DISABLE_QUIC:$DNS_HIJACK:$POLICY_MODE" "provider wins and manual mode ignored"
assert_true "both provider keys exposed" test "${PROVIDER_KEYS#*disable_quic}" != "$PROVIDER_KEYS"
fake_uci_set mihowrt.settings.provider_override 'disable_quic bypass_ntp'
fake_uci_set mihowrt.settings.bypass_ntp 0
settings_load
assert_eq '1:0:0' "$DISABLE_QUIC:$DNS_HIJACK:$BYPASS_NTP" "per-key and stale overrides"
sed -i '/set disable_quic/d' "$PROFILE_FILE"
settings_load
assert_eq 1 "$DISABLE_QUIC" "override survives key drop"
printf 'set disable_quic 0\n' >>"$PROFILE_FILE"
settings_load
assert_eq '1:0' "$DISABLE_QUIC:$DNS_HIJACK" "override survives re-add without affecting other key"
for source in merge own provider invalid; do
 fake_uci_set mihowrt.settings.dst_list_source "$source"
 settings_load
 expected="$source"; [ "$source" != invalid ] || expected=provider
 assert_eq "$expected" "$DST_LIST_SOURCE" "list source validation"
done
for auto in missing 1 0; do
 fake_uci_set mihowrt.settings.subscription_auto_update "$auto"
 [ "$auto" != missing ] || uci delete mihowrt.settings.subscription_auto_update
 for header in 12 08 000 0 9999 abc missing; do
  printf '{"header_interval":"%s"}\n' "$header" >"$tmpdir/meta"
  SUBSCRIPTION_META_FILE="$tmpdir/meta"
  [ "$header" != missing ] || echo '{}' >"$SUBSCRIPTION_META_FILE"
  expected=0
  if [ "$auto" != 0 ]; then
   case "$header" in 12) expected=12 ;; 08) expected=8 ;; esac
  fi
  assert_eq "$expected" "$(settings_subscription_interval)" "auto=$auto header=$header"
 done
done
pass "provider precedence, persistent per-key overrides, sources and provider schedule"
