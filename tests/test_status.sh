#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh lists.sh dns.sh nft.sh route.sh kernel.sh service.sh status.sh
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

json="$(status_json)"
assert_eq "true|true|true|null" "$(jq -r '"\(.running)|\(.dns_ok)|\(.policy_active)|\(.config_valid)"' <<<"$json")" "checklist flags"
assert_eq '["9.9.9.9"]' "$(jq -c .custom_dns_servers <<<"$json")" "only global custom servers reported"
assert_eq 2 "$(jq .lists.dst <<<"$json")" "list count ignores comments"
assert_eq "v1.19.32" "$(jq -r .core <<<"$json")" "core version"
pass "status checklist"

api_dns_probe() { false; }
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
