#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh
fake_uci_set network.lan.ipaddr 192.168.8.1/24
API_SECRET="s3cr3t-value-0001"
src="$tmpdir/src.yaml"
out="$tmpdir/out.yaml"

count() {
	grep -c -- "$1" "$out" || true
}

cat >"$src" <<'EOF'
mixed-port: 7890
tproxy-port: 1
allow-lan: false
secret: "x"
tun:
  enable: true
  stack: system
  dns-hijack:
    - any:53
dns:
    enable: false
    ipv6: true
    listen: 0.0.0.0:53
    enhanced-mode: redir-host
    nameserver:
    - 1.1.1.1
    fake-ip-filter:
      - '*.lan'
proxies:
  - name: a
    type: ss
rules:
  - MATCH,DIRECT
EOF

mihomo_config_generate "$src" "$out" || fail "generate must succeed"
assert_eq 1 "$(count '^tproxy-port: 7894$')" "single owned tproxy-port"
assert_eq 0 "$(count '^tproxy-port: 1$')" "user tproxy-port removed"
assert_eq 1 "$(count '^allow-lan: true$')" "allow-lan owned"
assert_eq 0 "$(count 'stack: system')" "tun children removed"
assert_eq 0 "$(count 'any:53')" "nested tun list removed"
assert_eq 1 "$(count '^secret: "s3cr3t-value-0001"$')" "secret from UCI"
assert_eq 1 "$(count '^external-controller: 192.168.8.1:9090$')" "controller on LAN IP"
assert_eq 1 "$(count '^mixed-port: 7890$')" "other ports kept"
pass "owned keys removed"

assert_eq 1 "$(count '^    ipv6: true$')" "dns ipv6 untouched"
assert_eq 1 "$(count '^    listen: 0.0.0.0:7874$')" "dns listen owned with source indent"
assert_eq 1 "$(count '^    enable: true$')" "dns enable owned"
assert_eq 1 "$(count '^    enhanced-mode: fake-ip$')" "fake-ip owned"
assert_eq 1 "$(count '^    fake-ip-range: 198.18.0.0/16$')" "fake-ip range owned"
assert_eq 0 "$(count 'redir-host')" "user enhanced-mode removed"
assert_eq 1 "$(count '^    - 1.1.1.1$')" "nameserver list kept"
assert_eq 1 "$(count "'\\*.lan'")" "fake-ip-filter kept"
assert_eq 1 "$(count '^dns:$')" "single dns block"
pass "dns children replaced"

sed -n '/^proxies:/,/MATCH,DIRECT/p' "$src" >"$tmpdir/a"
sed -n '/^proxies:/,/MATCH,DIRECT/p' "$out" >"$tmpdir/b"
cmp -s "$tmpdir/a" "$tmpdir/b" || fail "proxies/rules must be byte-identical"
pass "other sections preserved"

printf 'mode: rule\r\nproxies: []\r\n' >"$src"
mihomo_config_generate "$src" "$out" || fail "generate without dns must succeed"
assert_eq 1 "$(count '^dns:$')" "managed dns block added"
assert_eq 1 "$(count '^  enhanced-mode: fake-ip$')" "managed dns fake-ip"
assert_eq 0 "$(count $'\r')" "CRLF stripped"
pass "no dns block"

printf 'dns: {enable: true}\n' >"$src"
if mihomo_config_generate "$src" "$out" 2>/dev/null; then
	fail "flow-style dns must be rejected"
fi
pass "flow dns rejected"

fake_uci_reset
assert_eq "127.0.0.1" "$(lan_ip_detect)" "fallback controller address"
pass "lan ip fallback"

printf '"tproxy-port": 1\n'"'"'tun'"'"':\n  enable: true\nmode: rule\n' >"$src"
mihomo_config_generate "$src" "$out" || fail "quoted keys must generate"
assert_eq 1 "$(count 'tproxy-port')" "quoted owned key removed"
assert_eq 1 "$(count '^tun:$')" "only the managed tun block remains"
assert_eq 0 "$(grep -c "^'tun'" "$out" || true)" "quoted tun key gone"
pass "quoted owned keys removed"

printf 'dns: ~\nmode: rule\n' >"$src"
mihomo_config_generate "$src" "$out" || fail "scalar dns must generate"
assert_eq 0 "$(grep -c '^dns: ~' "$out" || true)" "scalar dns dropped"
assert_eq 1 "$(count '^dns:$')" "managed dns block used"
pass "scalar dns treated as absent"

# The shipped config leaves router-owned keys to the managed section.
for key in tproxy-port routing-mark allow-lan bind-address profile external-controller external-controller-unix; do
	if grep -q "^$key:" "$ROOT_DIR/rootfs/opt/clash/config.yaml"; then fail "built-in config sets router-owned $key"; fi
done
for key in enable listen enhanced-mode fake-ip-range; do
	if grep -q "^  $key:" "$ROOT_DIR/rootfs/opt/clash/config.yaml"; then fail "built-in config sets router-owned dns.$key"; fi
done
mihomo_config_generate "$ROOT_DIR/rootfs/opt/clash/config.yaml" "$out" || fail "built-in config must generate"
assert_eq 1 "$(count '^tproxy-port: 7894')" "managed tproxy-port"
assert_eq 1 "$(count '  enhanced-mode: fake-ip')" "managed dns mode"
assert_eq 1 "$(count '  fake-ip-filter-mode: whitelist')" "user dns options kept"
pass "built-in config is minimal"

# profile is router-owned: selection and fake-ip mappings survive restarts.
printf 'mode: rule\nprofile:\n  store-selected: false\n  store-fake-ip: false\nrules:\n  - MATCH,DIRECT\n' >"$src"
mihomo_config_generate "$src" "$out" || fail "generate with profile"
assert_eq 1 "$(count '^profile:')" "one profile block"
assert_eq 0 "$(count 'store-selected: false')" "user profile dropped"
assert_eq 1 "$(count '  store-selected: true')" "selection persisted"
assert_eq 1 "$(count '  store-fake-ip: true')" "fake-ip mappings persisted"
printf 'mode: rule\nprofile: {store-selected: false}\n' >"$src"
mihomo_config_generate "$src" "$out" || fail "generate with flow profile"
assert_eq 1 "$(count '^profile:')" "flow-style profile replaced"
pass "profile is router-owned"
