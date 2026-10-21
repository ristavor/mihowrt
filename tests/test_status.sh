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

printf '# Devices\naa:bb:cc:dd:ee:ff\n10.2.3.4\n' >"$SRC_LIST_FILE"
printf 'aa:bb:cc:dd:ee:ff\n' >"$DIRECT_SRC_LIST_FILE"
assert_eq '2:1' "$(status_json | jq -r '"\(.lists.src):\(.lists.direct_src)"')" 'status counts MAC and IP devices'
pass 'status MAC device counts'

CLASH_CONFIG_BACKUP="$tmpdir/config.yaml.bak"
assert_eq false "$(status_json | jq .config_backup)" 'no backup flag'
touch "$CLASH_CONFIG_BACKUP"
assert_eq true "$(status_json | jq .config_backup)" 'backup flag'
pass 'status backup flag'

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
