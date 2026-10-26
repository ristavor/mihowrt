#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh
setup_runtime_paths "$tmpdir"
fake_uci_set network.lan.ipaddr 192.168.8.1/24
API_SECRET="s3cr3t-value-0001"
out="$tmpdir/out.yaml"

# Count UCI commits; the fake uci treats commit as a no-op.
uci() {
	[ "${1:-}" != commit ] || echo x >>"$tmpdir/commits"
	command uci "$@"
}

# load_with <yaml>: write the YAML and reload settings from a fresh profile.
load_with() {
	printf '%s' "$1" >"$CLASH_CONFIG"
	rm -f "$PROFILE_FILE"
	settings_load
}

load_with 'proxies: []
'
assert_eq 0 "$BLOCK_CLIENT_IPV6" "default off"
pass "default off"

for v in true yes on 1 TRUE '"on"'; do
	printf 'proxies: []\nx-mihowrt:\n  block-client-ipv6: %s\n' "$v" >"$CLASH_CONFIG"
	cp "$CLASH_CONFIG" "$tmpdir/src.copy"
	mihomo_config_generate "$CLASH_CONFIG" "$out"
	assert_file_contains "$out.profile" 'set block_client_ipv6 1' "provider $v on"
	assert_file_not_contains "$out" x-mihowrt "extension stripped"
	cmp -s "$CLASH_CONFIG" "$tmpdir/src.copy" || fail "source YAML changed"
done
for v in false no off 0; do
	printf 'proxies: []\nx-mihowrt:\n  block-client-ipv6: %s\n' "$v" >"$CLASH_CONFIG"
	mihomo_config_generate "$CLASH_CONFIG" "$out"
	assert_file_contains "$out.profile" 'set block_client_ipv6 0' "provider $v off"
done
pass "provider boolean forms"

fake_uci_set mihowrt.settings.block_client_ipv6 1
load_with 'proxies: []
x-mihowrt:
  block-client-ipv6: maybe
'
assert_file_contains "$PROFILE_FILE" 'ignored block-client-ipv6' "invalid value ignored"
assert_file_not_contains "$PROFILE_FILE" 'set block_client_ipv6' "invalid value not applied"
assert_eq 1 "$BLOCK_CLIENT_IPV6" "invalid keeps UCI"
load_with 'proxies: []
'
assert_eq 1 "$BLOCK_CLIENT_IPV6" "missing keeps UCI"
pass "invalid falls back"

for pair in 'true 0 1 0' 'false 1 0 1'; do
	read -r -a args <<<"$pair"
	set -- "${args[@]}"
	uci delete mihowrt.settings.provider_override
	fake_uci_set mihowrt.settings.block_client_ipv6 "$2"
	yaml="proxies: []
x-mihowrt:
  block-client-ipv6: $1
"
	load_with "$yaml"
	assert_eq "$3" "$BLOCK_CLIENT_IPV6" "provider $1 wins over UCI $2"
	fake_uci_set mihowrt.settings.provider_override block_client_ipv6
	load_with "$yaml"
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override keeps own $2"
	load_with 'proxies: []
'
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override after key drop"
	load_with "$yaml"
	assert_eq "$4" "$BLOCK_CLIENT_IPV6" "override after key re-add"
done
pass "provider and own"

uci delete mihowrt.settings.provider_override
for flag in true false; do
	for core in 'ipv6: true' 'ipv6: false' ''; do
		for dns in '  ipv6: true' '  ipv6: false'; do
			yaml="${core:+$core
}dns:
$dns
proxies: []
x-mihowrt:
  block-client-ipv6: $flag
"
			fake_uci_set mihowrt.settings.block_client_ipv6 0
			load_with "$yaml"
			expected=0; [ "$flag" = false ] || expected=1
			assert_eq "$expected" "$BLOCK_CLIENT_IPV6" "flag $flag independent of '$core'/'$dns'"
			mihomo_config_generate "$CLASH_CONFIG" "$out"
			[ -z "$core" ] || grep -qxF "$core" "$out" || fail "core key preserved: $core"
			grep -qxF "$dns" "$out" || fail "DNS key preserved: $dns"
		done
	done
done
for core in 'ipv6: true' 'ipv6: false'; do
	fake_uci_set mihowrt.settings.block_client_ipv6 0
	load_with "$core
dns:
  ipv6: true
proxies: []
"
	assert_eq 0 "$BLOCK_CLIENT_IPV6" "no implicit activation from $core"
done
pass "independent core keys"

fake_uci_reset
fake_uci_set network.lan.ipaddr 192.168.8.1/24
rm -f "$tmpdir/commits"
cp "$FAKE_UCI_DB" "$tmpdir/uci.before"
load_with 'proxies: []
x-mihowrt:
  block-client-ipv6: on
'
assert_eq 1 "$BLOCK_CLIENT_IPV6" "provider on"
cmp -s "$FAKE_UCI_DB" "$tmpdir/uci.before" || fail "provider value persisted into UCI"
assert_false "no UCI commit" test -e "$tmpdir/commits"
pass "no persistence"

grep -q "option block_client_ipv6 '0'" "$ROOT_DIR/rootfs/etc/config/mihowrt" || fail "shipped default"
pass "shipped default off"
