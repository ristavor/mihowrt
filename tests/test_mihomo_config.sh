#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh
setup_runtime_paths "$tmpdir"

fake_uci_set network.lan.ipaddr 192.168.8.1/24
API_SECRET="s3cr3t-value-0001"
src="$tmpdir/src.yaml"
out="$tmpdir/out.yaml"

# Lock every successful fixture in this test to the pre-split generator bytes.
eval "$(declare -f mihomo_config_generate | sed '1s/mihomo_config_generate/generator_under_test/')"
printf '0\n' >"$tmpdir/generator-count"
mihomo_config_generate() {
 local index rc=0 golden
 index="$(cat "$tmpdir/generator-count")"
 index=$((index + 1))
 printf '%s\n' "$index" >"$tmpdir/generator-count"
 generator_under_test "$@" || rc=$?
 if [ "$rc" -eq 0 ]; then
  golden="$ROOT_DIR/tests/fixtures/generator/$index"
  cmp -s "$2" "$golden.yaml" || fail "generator golden $index runtime differs"
  cmp -s "$2.profile" "$golden.profile" || fail "generator golden $index profile differs"
 fi
 return "$rc"
}

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
assert_eq 1 "$(count '^    enhanced-mode: redir-host$')" "provider mode kept"
assert_eq 0 "$(count 'fake-ip-range:')" "no fake range in redir-host"

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
assert_eq 1 "$(count '^  enhanced-mode: redir-host$')" "managed dns fake-ip"
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
for key in enable listen fake-ip-range; do
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

cat >"$src" <<'Y'
ipv6: true
external-ui: ./x
external-ui-name: y
external-ui-url: http://evil
proxy-groups:
  - name: "🚀 Proxy"
x-mihowrt:
  disable-quic: false
  dns-hijack: yes
  lists-interval: 24
  proxy-ips:
    - '91.108.4.0/22' # comment
    - "https://p.example/t.txt;443"
  direct-ips: []
Y
mihomo_config_generate "$src" "$out"
assert_eq 1 "$(count '^external-ui: ui$')" "dashboard owned"
assert_file_contains "$out" "$MIHOMO_DASHBOARD_URL" "dashboard URL owned"
assert_file_not_contains "$out" external-ui-name "dashboard name dropped"
assert_file_not_contains "$out" x-mihowrt "extension stripped"
assert_file_contains "$out" '  ipv6: true' "default DNS follows IPv6"
assert_file_contains "$out" '"https://dns.google/dns-query#🚀 Proxy"' "emoji and space group suffix"
for server in https://1.1.1.1/dns-query https://9.9.9.9/dns-query https://8.8.8.8/dns-query; do
 assert_eq 2 "$(count "$server")" "default and proxy-server bootstrap"
done
assert_file_contains "$out" https://common.dot.dns.yandex.net/dns-query "direct DNS"
for line in 'set disable_quic 0' 'set dns_hijack 1' 'set lists_interval 24' 'has direct-ips' 'proxy-ip 91.108.4.0/22' 'proxy-ip https://p.example/t.txt;443'; do
 assert_file_contains "$out.profile" "$line" "profile $line"
done
assert_file_not_contains "$out.profile" 'direct-ip ' "empty direct provider list has no entries"
assert_eq 1 "$(count '^sniffer:$')" "default sniffer once"
for line in 'force-dns-mapping: true' 'parse-pure-ip: true' 'override-destination: false' 'ports: [80, 8080-8880]' 'ports: [443, 8443]'; do
 assert_file_contains "$out" "$line" "default sniffer $line"
done
assert_file_not_contains "$out" QUIC "no QUIC sniffer"
for group in '' 'A&B' 'A#B' 'A"B' 'A\B'; do
 printf 'proxy-groups:\n  - name: '\''%s'\''\n' "$group" >"$src"
 mihomo_config_generate "$src" "$out"
 assert_file_contains "$out" '"https://dns.google/dns-query"' "unsafe or absent suffix dropped"
 assert_file_contains "$out" '  ipv6: false' "IPv6 absent defaults false"
done
printf 'sniffer:\n  enable: false\n' >"$src"
mihomo_config_generate "$src" "$out"
assert_eq 1 "$(count '^sniffer:$')" "provider sniffer preserved once"
assert_file_contains "$out" '  enable: false' "provider sniffer untouched"
printf 'x-mihowrt: {a: 1}\n' >"$src"
assert_false "flow extension rejected" mihomo_config_generate "$src" "$out"
for mode in fake-ip redir-host normal missing; do
 for filter in whitelist blacklist rule; do
  printf 'dns:\n  fake-ip-filter-mode: %s\n  fake-ip-range6: fdfe::/64\n' "$filter" >"$src"
  [ "$mode" = missing ] || printf '  enhanced-mode: %s\n' "$mode" >>"$src"
  mihomo_config_generate "$src" "$out"
  expected=proxy-first
  if [ "$mode:$filter" = fake-ip:whitelist ]; then expected=direct-first; fi
  assert_file_contains "$out.profile" "mode $expected" "mode $mode/$filter"
  assert_file_contains "$out.profile" "dns ${mode/missing/redir-host}" "DNS profile"
  assert_file_not_contains "$out" fake-ip-range6 "IPv6 fake range dropped"
 done
done
cat >"$src" <<'Y'
x-mihowrt:
  disable-quic: maybe
  lists-interval: 9999
  netbird-proxy: true
  foo: 1
  proxy-ips: [1.2.3.4]
Y
mihomo_config_generate "$src" "$out"
for key in disable-quic lists-interval netbird-proxy foo proxy-ips; do
 assert_file_contains "$out.profile" "ignored $key" "invalid extension ignored"
done
assert_file_not_contains "$out.profile" 'set ' "invalid scalars not applied"
CLASH_CONFIG="$src"
PROFILE_FILE="$tmpdir/live.profile"
profile_ensure
assert_true "profile generated with service disabled" test -f "$PROFILE_FILE"
touch -d '2020-01-01' "$PROFILE_FILE" "$CLASH_CONFIG"
profile_ensure
assert_eq 1577836800 "$(stat -c %Y "$PROFILE_FILE")" "unchanged profile mtime"
printf 'dns:\n  enhanced-mode: normal\n' >"$CLASH_CONFIG"
profile_ensure
assert_eq normal "$(profile_get dns)" "newer YAML regenerates profile"
pass "provider DNS, defaults, extension validation and profile regeneration"

printf 'x-mihowrt:\n  proxy-ips:\n  - 1.2.3.4\n' >"$src"
mihomo_config_generate "$src" "$out"
assert_file_contains "$out.profile" 'proxy-ip 1.2.3.4' "same-indent list items"
printf "proxy-groups:\n  - name: \"Bob's Proxy\"\n" >"$src"
mihomo_config_generate "$src" "$out"
assert_file_contains "$out" "https://dns.google/dns-query#Bob's Proxy" "apostrophe group safe in double-quoted URL"
printf 'proxies: []\n' >"$src"
mihomo_config_generate "$src" "$out"
assert_file_contains "$out" '"https://dns.google/dns-query"' "no group uses suffixless DNS"
assert_file_contains "$out.profile" 'mode proxy-first' "no DNS proxy-first"
assert_file_contains "$out.profile" 'dns redir-host' "no DNS default profile"

for pair in true:1 false:0 yes:1 no:0 on:1 off:0 1:1 0:0; do
 printf 'x-mihowrt:\n  bypass-ntp: %s\n  bypass-subscription-dns: %s\n' "${pair%:*}" "${pair%:*}" >"$src"
 cp "$src" "$tmpdir/source.before"
 mihomo_config_generate "$src" "$out"
 cmp -s "$src" "$tmpdir/source.before" || fail "generator must not rewrite provider source"
 assert_file_contains "$out.profile" "set bypass_ntp ${pair#*:}" "provider boolean $pair"
 assert_file_contains "$out.profile" "set bypass_subscription_dns ${pair#*:}" "provider boolean $pair"
done
