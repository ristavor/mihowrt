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
# The frozen runtime fixtures describe an enabled dashboard.
DASHBOARD_ENABLED=1
src="$tmpdir/src.yaml"
out="$tmpdir/out.yaml"

# R5: inspect the actual external awk argv, not a shell mock.
(
 export AWK_ARGV="$tmpdir/awk.argv"
 real_awk="$(command -v awk)"
 cat >"$tmpdir/bin/awk" <<EOF
#!/bin/sh
printf '%s\\n' "\$@" >>"\$AWK_ARGV"
exec "$real_awk" "\$@"
EOF
 chmod +x "$tmpdir/bin/awk"
 printf 'proxies: []\n' >"$src"
 mihomo_config_generate "$src" "$out"
 assert_file_contains "$out" "secret: \"$API_SECRET\"" 'secret preserved from environment'
 assert_file_not_contains "$AWK_ARGV" "$API_SECRET" 'secret absent from awk argv'
 first="$(mihomo_config_key "$src")"
 API_SECRET=another-secret
 assert_false 'secret remains a config fingerprint input' test "$first" = "$(mihomo_config_key "$src")"
 rm "$tmpdir/bin/awk"
)
pass 'controller secret absent from awk argv'

# R28: controller exposure remains router-owned, including quoted/nested keys.
printf 'external-doh-server: /dns-query\n"external-controller-cors":\n  allow-origins: ["*"]\nproxies: []\n' >"$src"
mihomo_config_generate "$src" "$out"
assert_file_not_contains "$out" 'external-doh-server' 'subscription DoH listener stripped'
assert_file_not_contains "$out" 'allow-origins' 'subscription CORS children stripped'
pass 'controller exposure keys owned'

# R4: subscription log verbosity never overrides the router setting.
printf 'log-level: info\nproxies: []\n' >"$src"
for level in silent error warning info debug; do
 MIHOMO_LOG_LEVEL="$level" mihomo_config_generate "$src" "$out"
 assert_eq "log-level: $level" "$(grep '^log-level:' "$out")" 'router owns log detail'
done
pass 'router log detail overrides subscription'

# polish: generate filters once
(
 set -e
 once_src="$tmpdir/filter-once.yaml"
 once_out="$tmpdir/filter-once.runtime.yaml"
 printf 'x-mihowrt:\n  proxy-ips:\n    - https://10.0.0.1/rejected.txt\n' >"$once_src"
 : >"$tmpdir/generate.warnings"
 warn() { echo "$*" >>"$tmpdir/generate.warnings"; }
 mihomo_config_generate "$once_src" "$once_out"
 assert_file_not_contains "$once_out.profile" 'https://10.0.0.1/rejected.txt' 'generate filters once before profile publication'
 PROFILE_FILE="$once_out.profile"
 for _ in 1 2 3; do lists_source dst >/dev/null; done
 assert_eq 'x-mihowrt: ignored list URL https://10.0.0.1/rejected.txt (only public https URLs)' "$(grep 'ignored list URL' "$tmpdir/generate.warnings")" 'generate filters once: no repeated warnings on reads'
)
pass 'generate filters once'

# review C1: the profile holds the cleaned value, so spaces cannot hide a URL
(
 set -e
 ws_src="$tmpdir/filter-ws.yaml"
 ws_out="$tmpdir/filter-ws.runtime.yaml"
 printf 'x-mihowrt:\n  proxy-ips:\n    - "https:/ /10.0.0.1/x"\n    - 1.2.3.4#c https://x\n    - " 5.6.7.0/24 ; 443 "\n' >"$ws_src"
 : >"$tmpdir/ws.warnings"
 warn() { echo "$*" >>"$tmpdir/ws.warnings"; }
 mihomo_config_generate "$ws_src" "$ws_out"
 assert_eq $'proxy-ip 1.2.3.4\nproxy-ip 5.6.7.0/24;443' "$(grep '^proxy-ip ' "$ws_out.profile")" 'spaced URL dropped, plain IPs kept cleaned'
 assert_eq 'x-mihowrt: ignored list URL https://10.0.0.1/x (only public https URLs)' "$(grep 'ignored list URL' "$tmpdir/ws.warnings")" 'one warning for the spaced URL'
)
pass 'whitespace inside a provider URL is filtered'

# VM B1: the scratch build of profile_ensure does not log; the real build does
(
 set -e
 CLASH_CONFIG="$tmpdir/quiet.yaml"; PROFILE_FILE="$tmpdir/quiet.profile"
 printf 'x-mihowrt:\n  proxy-ips:\n    - https://10.0.0.1/q\n' >"$CLASH_CONFIG"
 rm -f "$PROFILE_FILE" "$tmpdir/quiet.log"
 logger() { echo "$*" >>"$tmpdir/quiet.log"; }
 profile_ensure
 assert_file_not_contains "$PROFILE_FILE" '10.0.0.1' 'profile_ensure still filters'
 assert_false 'profile_ensure logs nothing' test -s "$tmpdir/quiet.log"
 mihomo_config_generate "$CLASH_CONFIG" "$tmpdir/quiet.runtime.yaml"
 assert_file_contains "$tmpdir/quiet.log" 'ignored list URL https://10.0.0.1/q' 'the real build logs the warning'
)
pass "profile_ensure scratch build is quiet"

# Normalised keys must select the same form check and preserve block settings.
for dialect in gawk busybox; do
 (
 awk() { if [ "$dialect" = busybox ]; then busybox awk "$@"; else gawk "$@"; fi; }
 for section in dns x-mihowrt; do
  for style in plain spaced double single bom crlf; do
   key="$section"
   prefix=""; ending=$'\n'
   case "$style" in
    spaced) key="$section " ;;
    double) key="\"$section\"" ;;
    single) key="'$section'" ;;
    bom) prefix=$'\357\273\277' ;;
    crlf) ending=$'\r\n' ;;
   esac
   for value in block '~' null '{enable: true}' '[1.1.1.1]' foo; do
    if [ "$value" = block ]; then
     { printf '%s%s:%s' "$prefix" "$key" "$ending"
       tail -n +2 "$ROOT_DIR/tests/fixtures/yaml-forms/$section.yaml" | while IFS= read -r line; do
        printf '%s%s' "$line" "$ending"
       done
     } >"$src"
    else
     printf '%s%s: %s # form%s' "$prefix" "$key" "$value" "$ending" >"$src"
    fi
    cp "$src" "$tmpdir/form-source.before"
    assert_true "$dialect/$section/$style/$value top key detected" yaml_has_top_key "$section" "$src"
    assert_false "$dialect/$section/$style no partial key match" yaml_has_top_key "${section%-*}" <(printf '%s-extra: {}\n' "$section")
    label="$dialect/$section/$style/$value"
    case "$value" in
     block|'~'|null)
      mihomo_config_generate "$src" "$out" || fail "$label must generate"
      if [ "$value" = block ]; then
       if [ "$section" = dns ]; then
        assert_file_contains "$out.profile" 'dns fake-ip' "$label DNS mode preserved"
        assert_file_contains "$out.profile" 'mode direct-first' "$label filter preserved"
        assert_file_contains "$out" '    - 1.1.1.1' "$label nameserver preserved"
       else
        assert_file_contains "$out.profile" 'set disable_quic 0' "$label extension preserved"
        assert_file_contains "$out.profile" 'proxy-ip 1.2.3.4' "$label list preserved"
        assert_file_not_contains "$out" x-mihowrt "$label extension removed"
       fi
      else
       assert_file_contains "$out.profile" 'dns redir-host' "$label managed DNS"
       assert_file_not_contains "$out.profile" 'set disable_quic' "$label null extension"
      fi ;;
     *)
      printf 'previous runtime\n' >"$out"
      printf 'previous profile\n' >"$out.profile"
      assert_false "$label rejected" mihomo_config_generate "$src" "$out" 2>"$tmpdir/form.error"
      assert_file_contains "$tmpdir/form.error" "Unsupported $section form: use a block mapping" "$label precise error"
      assert_eq 'previous runtime' "$(cat "$out")" "$label runtime not published"
      assert_eq 'previous profile' "$(cat "$out.profile")" "$label profile not published"
      assert_false "$label staging removed" test -e "$out.tmp.$$" ;;
    esac
    assert_true "$label source unchanged" cmp -s "$src" "$tmpdir/form-source.before"
   done
  done
 done
 pass "$dialect normalised DNS and extension forms"
 )
done

# Lock baseline bytes, plus the E10 listener/rule in proxy-first fake-IP.
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
for key in log-level tproxy-port routing-mark allow-lan bind-address profile external-controller external-controller-unix; do
	if grep -q "^$key:" "$ROOT_DIR/rootfs/opt/clash/config.yaml"; then fail "built-in config sets router-owned $key"; fi
done
for key in enable listen fake-ip-range; do
	if grep -q "^  $key:" "$ROOT_DIR/rootfs/opt/clash/config.yaml"; then fail "built-in config sets router-owned dns.$key"; fi
done
assert_file_not_contains "$ROOT_DIR/rootfs/opt/clash/config.yaml" 'rule-providers:' 'built-in config has no remote rule-provider'
assert_file_not_contains "$ROOT_DIR/rootfs/opt/clash/config.yaml" 'rule-set:' 'built-in config has no dangling rule-set filter'
assert_file_contains "$ROOT_DIR/rootfs/opt/clash/config.yaml" '  fake-ip-filter: []' 'built-in whitelist has no proxy domains without a subscription'
mihomo_config_generate "$ROOT_DIR/rootfs/opt/clash/config.yaml" "$out" || fail "built-in config must generate"
assert_eq 1 "$(count '^tproxy-port: 7894')" "managed tproxy-port"
assert_eq 1 "$(count '  enhanced-mode: fake-ip')" "managed dns mode"
assert_eq 1 "$(count '  fake-ip-filter-mode: whitelist')" "user dns options kept"
assert_file_contains "$out.profile" 'mode direct-first' 'built-in config stays direct-first'
assert_file_not_contains "$out" 'rule-providers:' 'built-in runtime has no rule-provider'
assert_file_contains "$out" '  fake-ip-filter: []' 'built-in runtime keeps the empty whitelist'
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
DASHBOARD_ENABLED=0 generator_under_test "$src" "$out"
assert_eq 0 "$(count '^external-ui')" "dashboard off: no external-ui keys"
assert_file_not_contains "$out" "$MIHOMO_DASHBOARD_URL" "dashboard off: no download URL"
DASHBOARD_ENABLED=1 mihomo_config_generate "$src" "$out"
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
