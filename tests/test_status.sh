#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh lists.sh dns.sh nft.sh route.sh kernel.sh service.sh status.sh
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
assert_eq "true|true|true|true" "$(jq -r '"\(.running)|\(.dns_ok)|\(.policy_active)|\(.config_valid)"' <<<"$json")" "checklist flags"
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
