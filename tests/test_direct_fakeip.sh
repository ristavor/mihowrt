#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh nft.sh
setup_runtime_paths "$tmpdir"
API_SECRET=s3cr3t-value-0001
src="$tmpdir/source.yaml"
out="$tmpdir/runtime.yaml"

# Exercise the runtime generator with both deployed awk dialects. DNS may follow
# listeners/rules; injection must not depend on document key ordering.
for dialect in gawk busybox; do
 (
 awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
 warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
 for style in missing empty null block indentless collision; do
  : >"$src"
  case "$style" in
   empty) printf 'listeners: [] # empty\nrules: []\n' >>"$src" ;;
   null) printf 'listeners: null\nrules: ~\n' >>"$src" ;;
   block|collision)
    cat >>"$src" <<'EOF'
listeners:
  - name: provider-inbound # retained
    type: mixed
    port: 17890
rules:
  # provider rule comment retained
  - DOMAIN,provider.example,REJECT
  - MATCH,DIRECT
EOF
    if [ "$style" = collision ]; then
     # Name can follow type and be quoted; remove this whole entry only.
     sed -i '/^rules:/i\  - type: tproxy\n    name: "mihowrt-direct"\n    port: 17891' "$src"
    fi ;;
   indentless) printf 'listeners:\n- name: provider-inbound\n  type: mixed\n  port: 17890\nrules:\n- MATCH,DIRECT\n' >>"$src" ;;
  esac
  printf 'dns:\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: blacklist\nproxies: []\n' >>"$src"
  cp "$src" "$tmpdir/source-copy"
  : >"$tmpdir/warnings"
  mihomo_config_generate "$src" "$out"
  assert_file_contains "$out.profile" "direct_listener 1" "$dialect/$style listener profile"
  assert_file_not_contains "$out.profile" "set direct_listener" "$dialect/$style listener not a provider key"
  assert_true "$dialect/$style source untouched" cmp -s "$src" "$tmpdir/source-copy"
  assert_eq 1 "$(grep -c '^listeners:' "$out")" "$dialect/$style one listener block"
  assert_eq 1 "$(grep -c '^rules:' "$out")" "$dialect/$style one rule block"
  assert_file_contains "$out" 'name: mihowrt-direct' "$dialect/$style dedicated inbound"
  assert_file_contains "$out" "port: $MIHOMO_DIRECT_TPROXY_PORT" "$dialect/$style dedicated port"
  assert_eq "IN-NAME,mihowrt-direct,DIRECT" "$(awk '/^rules:/ {r=1;next} r && /^[[:space:]]*-/ {sub(/^[[:space:]]*-[[:space:]]*/, "");print;exit}' "$out")" "$dialect/$style first rule"
  case "$style" in
   block|collision|indentless)
    assert_file_contains "$out" 'name: provider-inbound' "$dialect/$style provider listener kept"
    assert_file_contains "$out" 'MATCH,DIRECT' "$dialect/$style provider rule kept" ;;
  esac
  if [ "$style" = collision ]; then
   assert_file_not_contains "$out" 17891 "$dialect collision entry removed"
   assert_file_contains "$tmpdir/warnings" 'mihowrt-direct' "$dialect collision warned"
  fi
  if [ "$style" = block ]; then
   sed -n '/^  - name: provider-inbound/,/^rules:/p' "$out" | sed '$d' >"$tmpdir/provider.actual"
   printf '  - name: provider-inbound # retained\n    type: mixed\n    port: 17890\n' >"$tmpdir/provider.expected"
   assert_true "$dialect provider entry verbatim" cmp -s "$tmpdir/provider.expected" "$tmpdir/provider.actual"
   assert_file_contains "$out" '# provider rule comment retained' "$dialect rule comment kept"
  fi
 done
 for unsupported in 'listeners: [{name: custom, type: mixed, port: 17890}]' 'rules: [MATCH,DIRECT]' 'listeners: *shared' 'listeners: &shared []' $'listeners:\n  - name: mihowrt-direct\n    type: mixed\n    port: 17891\nrules: [MATCH,DIRECT]' $'listeners: []\nlisteners: []' $'rules: []\nrules: []' 'listeners: |' $'listeners:\n  - {name: custom, type: mixed}' $'listeners:\n  - *shared' 'listeners:
  - name: "mihowrt-\u0064irect"
    type: tproxy
    port: 17891'; do
  printf '%s\ndns:\n  enhanced-mode: fake-ip\n' "$unsupported" >"$src"
  # Whitelist disables injection: remove only that added line for the baseline.
  sed '/enhanced-mode:/a\  fake-ip-filter-mode: whitelist' "$src" >"$tmpdir/baseline-source"
  mihomo_config_generate "$tmpdir/baseline-source" "$tmpdir/baseline"
  sed '/fake-ip-filter-mode: whitelist/d' "$tmpdir/baseline" >"$tmpdir/expected"
  : >"$tmpdir/warnings"
  assert_true "$dialect unsupported injection falls back" mihomo_config_generate "$src" "$out"
  assert_true "$dialect fallback preserves pre-injection runtime" cmp -s "$out" "$tmpdir/expected"
  assert_file_not_contains "$out" 'IN-NAME,mihowrt-direct,DIRECT' "$dialect no injected rule"
  assert_file_not_contains "$out" "port: $MIHOMO_DIRECT_TPROXY_PORT" "$dialect no injected listener"
  assert_file_not_contains "$out.profile" 'direct_listener 1' "$dialect no listener profile"
  assert_eq 1 "$(wc -l <"$tmpdir/warnings" | tr -d ' ')" "$dialect one fallback warning"
  assert_file_contains "$tmpdir/warnings" 'Devices always direct with fake-IP DNS is unavailable' "$dialect fallback warning"
 done
 for mode in whitelist redir-host normal; do
  if [ "$mode" = whitelist ]; then
   printf 'dns:\n  enhanced-mode: fake-ip\n  fake-ip-filter-mode: whitelist\n' >"$src"
  else
   printf 'dns:\n  enhanced-mode: %s\n' "$mode" >"$src"
  fi
  printf 'listeners: [{name: custom, type: mixed, port: 17890}]\nrules: [MATCH,DIRECT]\n' >>"$src"
  mihomo_config_generate "$src" "$out"
  assert_file_not_contains "$out.profile" "direct_listener 1" "$dialect/$mode no listener profile"
  assert_file_not_contains "$out" mihowrt-direct "$dialect/$mode no injection"
  assert_file_contains "$out" 'listeners: [{name: custom, type: mixed, port: 17890}]' "$dialect/$mode untouched flow block"
 done
 pass "$dialect direct fake-IP YAML injection"
 )
done

settings_load
POLICY_MODE=proxy-first
DNS_MODE=fake-ip
DIRECT_LISTENER=1
DISABLE_QUIC=1
mkdir -p "$tmpdir/work"
printf 'aa:bb:cc:dd:ee:ff\n192.0.2.2\n2001:db8::2\n192.0.2.3;80,443\n2001:db8::3;443\n;8080\n' >"$DIRECT_SRC_LIST_FILE"
ip() { return 0; }
nft_render "$out" "$tmpdir/work"
for match in 'ether saddr @direct_src_mac' 'ip saddr @direct_src' 'ip6 saddr @direct_src6' 'ip saddr { 192.0.2.3 } meta l4proto { tcp, udp } th dport { 80,443 }' 'ip6 saddr { 2001:db8::3 } meta l4proto { tcp, udp } th dport { 443 }' 'meta nfproto ipv4 meta l4proto { tcp, udp } th dport { 8080 }'; do
 assert_file_contains "$out" "prerouting_policy $match goto direct_device_policy" "fake-IP device form: $match"
done
assert_file_contains "$out" 'add element inet mihowrt direct_src_mac { aa:bb:cc:dd:ee:ff }' 'fake-IP fills device sets'
expected="add rule inet mihowrt direct_device_policy meta nfproto ipv6 return
add rule inet mihowrt direct_device_policy ip daddr != $FAKEIP_RANGE return
add rule inet mihowrt direct_device_policy ip daddr $FAKEIP_RANGE udp dport 443 reject
add rule inet mihowrt direct_device_policy ip daddr $FAKEIP_RANGE meta l4proto { tcp, udp } meta mark set meta mark | $NFT_INTERCEPT_MARK | $NFT_DIRECT_MARK accept"
assert_eq "$expected" "$(grep '^add rule inet mihowrt direct_device_policy ' "$out")" 'real destinations return, fake QUIC rejects before direct marking'
first="$(grep '^add rule inet mihowrt proxy_redirect ' "$out" | sed -n '2p')"
assert_eq "add rule inet mihowrt proxy_redirect meta mark & $NFT_DIRECT_MARK == $NFT_DIRECT_MARK meta nfproto ipv4 meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:$MIHOMO_DIRECT_TPROXY_PORT accept" "$first" 'dedicated TPROXY terminates before generic TPROXY'
assert_file_not_contains "$out" 'mangle_output meta mark & 0x04000000' 'router output does not select direct devices'
DISABLE_QUIC=0
nft_render "$out" "$tmpdir/work"
assert_file_not_contains "$out" 'udp dport 443 reject' 'fake direct QUIC allowed when disabled'
pass 'fake-IP direct devices nft policy'

DIRECT_LISTENER=0
nft_render "$out" "$tmpdir/work"
assert_file_not_contains "$out" direct_device_policy 'no fake-IP direct chain without listener'
assert_file_not_contains "$out" "127.0.0.1:$MIHOMO_DIRECT_TPROXY_PORT" 'no dedicated TPROXY without listener'
assert_file_not_contains "$out" 'prerouting_policy ether saddr @direct_src' 'fake-IP direct devices skipped without listener'
assert_file_not_contains "$out" 'add element inet mihowrt direct_src' 'no direct source sets populated without listener'
assert_file_contains "$out" "prerouting_policy meta l4proto { tcp, udp } meta mark set" 'fallback keeps generic fake-IP interception'
printf 'mode proxy-first\ndns fake-ip\ndirect_listener 1\n' >"$PROFILE_FILE"
settings_load
assert_eq 1 "$DIRECT_LISTENER" 'settings loads injected listener flag'
printf 'mode proxy-first\ndns fake-ip\n' >"$PROFILE_FILE"
settings_load
assert_eq 0 "$DIRECT_LISTENER" 'settings resets absent listener flag'
pass 'fake-IP direct devices fallback without listener'
