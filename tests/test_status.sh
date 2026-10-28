#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh lists.sh dns.sh nft.sh route.sh core.sh service.sh status.sh
setup_runtime_paths "$tmpdir"

PKG_TMP_DIR="$tmpdir/tmp"
RUNTIME_CONFIG="$tmpdir/runtime.yaml"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/dst"
SRC_LIST_FILE="$LIST_DIR/src"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct"
lists_ensure_files
printf '1.1.1.1\n# c\n2001:db8::1\n' >"$DST_LIST_FILE"
echo "mode: rule" >"$RUNTIME_CONFIG"
fake_uci_set dhcp.cfg01 dnsmasq
fake_uci_set dhcp.cfg01.server "'9.9.9.9' '/corp.lan/10.0.0.2'"
service_running() { true; }
service_enabled() { true; }
api_dns_probe() { true; }
nft_active() { true; }
route_active() { true; }
core_version() { echo v1.19.32; }

echo ok >"$HEALTH_FILE"
json="$(status_json)"
assert_eq "true|true|true|null" "$(jq -r '"\(.running)|\(.dns_ok)|\(.policy_active)|\(.config_valid)"' <<<"$json")" "checklist flags"
assert_eq '["9.9.9.9"]' "$(jq -c .custom_dns_servers <<<"$json")" "only global custom servers reported"
assert_eq 2 "$(jq .lists.dst <<<"$json")" "list count ignores comments"
assert_eq "v1.19.32" "$(jq -r .core <<<"$json")" "core version"
pass "status checklist"

(
 load_modules nft.sh
 nft() { printf '%s\n' "$*" >"$tmpdir/status-nft.calls"; }
 json="$(status_json)"
 assert_eq true "$(jq .policy_active <<<"$json")" 'status uses real nft active check'
 assert_eq '-t list table inet mihowrt' "$(cat "$tmpdir/status-nft.calls")" 'status nft check skips set elements'
)
pass 'status uses terse nft active check'

subscription_failed=false
for entry in 'http://p/x|true|http flagged' 'HTTP://p/x|true|case insensitive' 'https://p/x|false|https not flagged' '|false|empty url false'; do
 IFS='|' read -r url expected name <<<"$entry"
 fake_uci_set mihowrt.settings.subscription_url "$url"
 if (assert_eq "$expected" "$(status_json | jq .subscription_insecure)" "$name"); then
  pass "status subscription $name"
 else
  subscription_failed=true
 fi
done
[ "$subscription_failed" = false ] || fail 'status subscription security flags'

echo fail >"$HEALTH_FILE"
api_dns_probe() { fail "status must not probe DNS"; }
assert_eq false "$(status_json | jq .dns_ok)" "failed DNS probe reported"
pass "status dns failure"

logread() { for i in $(seq 1 1500); do echo "mihowrt: line $i"; done; echo "other: x"; }
assert_eq 1000 "$(logs_json 5000 | jq '.lines | length')" "logs clamped to 1000"
assert_eq 200 "$(logs_json abc | jq '.lines | length')" "invalid limit uses 200"
assert_eq "mihowrt: line 1500" "$(logs_json 1 | jq -r '.lines[0]')" "newest line kept"
pass "logs clamp"

printf 'mode: rule\n' >"$CLASH_CONFIG"
service_running() { false; }
CLASH_BIN="$tmpdir/core"
printf '#!/bin/sh\ntouch "%s"\n' "$tmpdir/core.called" >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
json="$(status_json)"
assert_false "status never invokes core" test -e "$tmpdir/core.called"
touch "$CONFIG_OK_FILE"
assert_eq true "$(status_json | jq .config_valid)" "recorded success"
rm "$CONFIG_OK_FILE"
printf 'bad proxy type\n' >"$CONFIG_ERR_FILE"
assert_eq 'false:bad proxy type' "$(status_json | jq -r '"\(.config_valid):\(.config_error)"')" "recorded error"
touch -d '2000-01-01' "$CONFIG_ERR_FILE"
assert_eq null "$(status_json | jq .config_valid)" "new YAML invalidates result"
printf 'mode proxy-first\ndns redir-host\nset disable_quic 0\nhas proxy-ips\nproxy-ip 1.2.3.4\n' >"$PROFILE_FILE"
fake_uci_set mihowrt.settings.provider_override disable_quic
profile_json | jq -e '.provider.disable_quic == "0" and .overrides == ["disable_quic"] and .lists.dst.provided and .lists.dst.source == "provider"' >/dev/null || fail "profile-json contract"
pass "status check state, core not called and profile-json"

printf 'mode proxy-first\ndns redir-host\nset block_client_ipv6 1\n' >"$PROFILE_FILE"
fake_uci_set mihowrt.settings.block_client_ipv6 0
fake_uci_set mihowrt.settings.provider_override block_client_ipv6
profile_json | jq -e '.provider.block_client_ipv6 == "1" and .overrides == ["block_client_ipv6"]' >/dev/null || fail "client IPv6 provider value and override"
for extra in '' 'ignored block-client-ipv6'; do
 printf 'mode proxy-first\ndns redir-host\n%s\n' "$extra" >"$PROFILE_FILE"
 profile_json | jq -e '.provider | has("block_client_ipv6") | not' >/dev/null || fail "absent or invalid provider key not guessed"
done
uci delete mihowrt.settings.provider_override
uci delete mihowrt.settings.block_client_ipv6
pass "profile-json client IPv6 provider key"

printf '# Devices\naa:bb:cc:dd:ee:ff\n10.2.3.4\n' >"$SRC_LIST_FILE"
printf 'aa:bb:cc:dd:ee:ff\n' >"$DIRECT_SRC_LIST_FILE"
assert_eq '2:1' "$(status_json | jq -r '"\(.lists.src):\(.lists.direct_src)"')" 'status counts MAC and IP devices'
pass 'status MAC device counts'

CLASH_CONFIG_BACKUP="$tmpdir/config.yaml.bak"
assert_eq false "$(status_json | jq .config_backup)" 'no backup flag'
touch "$CLASH_CONFIG_BACKUP"
assert_eq true "$(status_json | jq .config_backup)" 'backup flag'
pass 'status backup flag'

# Diagnostics needs the stored flag next to the mode to say whether it has any effect.
assert_eq false "$(status_json | jq .block_client_ipv6)" 'client IPv6 flag off by default'
fake_uci_set mihowrt.settings.block_client_ipv6 1
assert_eq true "$(status_json | jq .block_client_ipv6)" 'client IPv6 flag reported'
uci delete mihowrt.settings.block_client_ipv6
pass 'status client IPv6 flag'

# Every state-table row, including precedence when multiple files exist.
service_running() { true; }
touch "$DEGRADED_FILE" "$RUNNING_MARKER" "$USER_STOP_FILE" "$LAST_ERROR_FILE"
assert_eq degraded "$(service_state)" 'alive degraded wins'
rm "$DEGRADED_FILE"
assert_eq running "$(service_state)" 'alive running marker'
rm "$RUNNING_MARKER"
assert_eq starting "$(service_state)" 'alive without marker'
service_running() { false; }
assert_eq stopped "$(service_state)" 'user stop wins over error'
rm "$USER_STOP_FILE"
assert_eq failed "$(service_state)" 'dead with error'
rm "$LAST_ERROR_FILE"
assert_eq stopped "$(service_state)" 'dead without error'
pass 'service state table'

# Exercise real core_version and service_enabled; only the full status may load settings.
load_modules core.sh status.sh
printf '#!/bin/sh\necho called >>"%s"\necho "Mihomo v1.19.32"\n' "$tmpdir/core.calls" >"$CLASH_BIN"
chmod +x "$CLASH_BIN"
echo v1.19.32 >"$CORE_VERSION_CACHE"
touch -d '2000-01-01' "$CLASH_BIN"
curl() { echo called >>"$tmpdir/curl.calls"; return 1; }
api_dns_probe() { curl; }
echo 'failure "quoted"' >"$LAST_ERROR_FILE"
for health in ok fail missing; do
 case "$health" in ok) expected=true ;; fail) expected=false ;; missing) expected=null ;; esac
 if [ "$health" = missing ]; then rm -f "$HEALTH_FILE"; else echo "$health" >"$HEALTH_FILE"; fi
 (
  settings_load() { fail 'cheap status must not load settings'; }
  uci() { fail 'cheap status must not call uci'; }
  json="$(service_state_json)"
  assert_eq "$expected" "$(jq .dns_ok <<<"$json")" 'cheap health snapshot'
  jq -e '.running == false and (.enabled | type) == "boolean" and .state == "failed" and .last_error == "failure \"quoted\"" and (keys | length) == 5' <<<"$json" >/dev/null || fail 'cheap JSON contract'
 )
 json="$(status_json)"
 assert_eq "$expected" "$(jq .dns_ok <<<"$json")" 'full status health snapshot'
 assert_eq failed "$(jq -r .state <<<"$json")" 'full status state'
 assert_eq 'failure "quoted"' "$(jq -r .last_error <<<"$json")" 'full status error'
done
assert_false 'status does not call API' test -e "$tmpdir/curl.calls"
assert_false 'fresh cache avoids core invocation' test -e "$tmpdir/core.calls"
touch -d '2001-01-01' "$CORE_VERSION_CACHE"
touch "$CLASH_BIN"
json="$(status_json)"
json="$(status_json)"
assert_eq 1 "$(wc -l <"$tmpdir/core.calls" | tr -d ' ')" 'new binary queried exactly once'
assert_eq v1.19.32 "$(cat "$CORE_VERSION_CACHE")" 'cache refreshed'
pass 'cheap status uses health files and cached core version'

(
 # Relocate only the fixed init paths, keeping the real enabled-check logic.
 eval "$(declare -f service_enabled | sed "s|/etc/|$tmpdir/etc/|g")"
 mkdir -p "$tmpdir/etc/rc.d" "$tmpdir/etc/init.d"
 printf '#!/bin/sh\ntouch "%s"\n' "$tmpdir/init.called" >"$tmpdir/etc/init.d/mihowrt"
 chmod +x "$tmpdir/etc/init.d/mihowrt"
 assert_false 'no start link means disabled' service_enabled
 ln -s ../init.d/mihowrt "$tmpdir/etc/rc.d/S21mihowrt"
 assert_true 'start link means enabled' service_enabled
 assert_false 'enabled never invokes init' test -e "$tmpdir/init.called"
)
assert_eq service-state-json "$(MIHOWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" service-state-json)" 'read wrapper exposes cheap status'
assert_false 'cheap read command rejects arguments' env MIHOWRT_BACKEND=/bin/echo ash "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" service-state-json extra
pass 'cheap enabled flag and read wrapper'

# PID state is sampled once, even if the process changes between checks.
(
 service_running() { echo checked >>"$tmpdir/pid-checks"; true; }
 printf 'first line\nsecond \\ line\n' >"$LAST_ERROR_FILE"
 json="$(service_state_json)"
 assert_eq 1 "$(wc -l <"$tmpdir/pid-checks" | tr -d ' ')" 'cheap status checks PID once'
 assert_eq 'first line
second \ line' "$(jq -r .last_error <<<"$json")" 'multiline error preserved literally'
)
pass 'service-state-json single PID snapshot and literal errors'

printf 'ok\nunexpected\n' >"$HEALTH_FILE"
assert_eq null "$(health_json)" 'malformed health snapshot stays unknown'
printf 'ok\n\n' >"$HEALTH_FILE"
assert_eq true "$(health_json)" 'health trailing newlines retain previous meaning'
pass 'health file exact snapshot semantics'

CLASH_DIR="$tmpdir/dashboard"
mkdir -p "$CLASH_DIR/ui"
for installed in false true; do
 rm -f "$CLASH_DIR/ui/index.html"
 [ "$installed" != true ] || touch "$CLASH_DIR/ui/index.html"
 assert_eq "$installed" "$(status_json | jq .dashboard_installed)" 'status dashboard install flag'
 assert_eq "$installed" "$(profile_json | jq .dashboard_installed)" 'profile dashboard install flag'
done
pass 'status and profile expose cheap dashboard installation flag'

(
 lan_ip_detect() { echo called >>"$tmpdir/lan.calls"; echo 192.0.2.25; }
 assert_eq 192.0.2.25 "$(status_json | jq -r .dashboard_host)" 'status includes nonsecret dashboard host'
 rm "$tmpdir/lan.calls"
 service_state_json >/dev/null
 assert_false 'polled state does not detect LAN address' test -e "$tmpdir/lan.calls"
)
awk 'BEGIN { printf "%0200000d\n", 1 }' >"$LAST_ERROR_FILE"
json="$(status_json)"
assert_true 'huge snapshot gives bounded JSON error' test "$(jq -rj .last_error <<<"$json" | wc -c)" -le 4096
last_error_record "$LAST_ERROR_FILE"
assert_true 'recorded start error bounded' test "$(wc -c <"$LAST_ERROR_FILE")" -le 4096
CONFIG_TEST_OUTPUT="$(awk 'BEGIN { for (i=0;i<25;i++) printf "%010000d\n", i }')"
config_check_record err
assert_true 'recorded config error bounded' test "$(wc -c <"$CONFIG_ERR_FILE")" -le 4096
assert_true 'config error lines bounded' test "$(awk 'length > n { n=length } END { print n }' "$CONFIG_ERR_FILE")" -le 1000
pass 'huge status and recorded errors stay bounded'

(
 awk() { touch "$tmpdir/error-awk-called"; command awk "$@"; }
 : >"$tmpdir/empty-error"
 assert_eq '' "$(error_text "$tmpdir/empty-error")" 'empty diagnostic snapshot'
 assert_eq '' "$(error_text "$tmpdir/missing-error" 2>/dev/null)" 'missing diagnostic snapshot'
 assert_false 'empty error snapshots never fork awk' test -e "$tmpdir/error-awk-called"
)
pass 'empty error snapshots stay fork-free'

# The real JSON consumer replaces a trailing byte fragment rather than emitting invalid UTF-8.
printf '%0999dЖ' 0 >"$LAST_ERROR_FILE"
assert_eq 1000 "$(error_text "$LAST_ERROR_FILE" | tr -d '\n' | wc -c)" 'diagnostic cut lands inside Cyrillic character'
json="$(status_json)"
printf '%s\n' "$json" >"$tmpdir/utf8-status.json"
node - "$tmpdir/utf8-status.json" <<'NODE'
const fs = require('fs');
const text = new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(process.argv[2]));
const data = JSON.parse(text);
if (!data.last_error.startsWith('0'.repeat(999))) throw new Error('diagnostic prefix lost');
NODE
pass 'byte-cut UTF-8 diagnostic survives real status JSON consumer'
