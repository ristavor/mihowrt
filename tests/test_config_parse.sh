#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmpbin/logger"
export PATH="$tmpbin:$PATH"
export CLASH_CONFIG="$tmpdir/config.yaml"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

assert_eq "5353" "$(port_from_addr '127.0.0.1:5353')" "port_from_addr parses IPv4 host:port"
assert_eq "7874" "$(port_from_addr '[::]:7874')" "port_from_addr parses bracketed IPv6 host:port"
assert_false "port_from_addr should reject plain IPv6 address" port_from_addr "2001:db8::1"
assert_eq "127.0.0.1#7874" "$(normalize_dns_server_target '0.0.0.0#7874')" "normalize_dns_server_target rewrites wildcard IPv4"
assert_eq "127.0.0.1#7874" "$(normalize_dns_server_target '[::]#7874')" "normalize_dns_server_target rewrites wildcard IPv6"
assert_eq "127.0.0.1#7874" "$(normalize_dns_server_target_from_addr '0.0.0.0:7874')" "normalize_dns_server_target_from_addr rewrites wildcard IPv4"
assert_eq "192.168.70.1#7874" "$(normalize_dns_server_target_from_addr '192.168.70.1:7874')" "normalize_dns_server_target_from_addr preserves bound IPv4 host"
assert_eq "value" "$(yaml_cleanup_scalar '  value   # comment')" "yaml_cleanup_scalar trims inline comment"
assert_eq "quoted value" "$(yaml_cleanup_scalar '"quoted value"')" "yaml_cleanup_scalar strips double quotes"
assert_eq "single quoted" "$(yaml_cleanup_scalar "'single quoted'")" "yaml_cleanup_scalar strips single quotes"

cat > "$CLASH_CONFIG" <<'EOF'
mode: rule
tproxy-port: 7894
routing-mark: 2
external-controller: 0.0.0.0:9090
external-controller-tls: :9443
secret: "abc123"
external-ui: ./ui
external-ui-name: zashboard

dns:
  listen: 0.0.0.0:7874
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.0/15
EOF

config_json="$(read_config_json)"

assert_eq "7874" "$(printf '%s\n' "$config_json" | jq -r '.dns_port')" "read_config_json extracts dns port"
assert_eq "127.0.0.1#7874" "$(printf '%s\n' "$config_json" | jq -r '.mihomo_dns_listen')" "read_config_json normalizes dns listen target"
assert_eq "7894" "$(printf '%s\n' "$config_json" | jq -r '.tproxy_port')" "read_config_json extracts tproxy port"
assert_eq "2" "$(printf '%s\n' "$config_json" | jq -r '.routing_mark')" "read_config_json extracts routing mark"
assert_eq "true" "$(printf '%s\n' "$config_json" | jq -r '.catch_fakeip')" "read_config_json enables fake-ip catch"
assert_eq "198.18.0.0/15" "$(printf '%s\n' "$config_json" | jq -r '.fake_ip_range')" "read_config_json extracts fake-ip range"
assert_eq "zashboard" "$(printf '%s\n' "$config_json" | jq -r '.external_ui_name')" "read_config_json extracts external UI name"
assert_eq "0" "$(printf '%s\n' "$config_json" | jq -r '.errors | length')" "read_config_json should not emit errors for valid config"

cat > "$CLASH_CONFIG" <<'EOF'
tproxy-port: 7894
routing-mark: 2

dns:
  listen: 192.168.70.1:7874
EOF

bound_json="$(read_config_json)"

assert_eq "7874" "$(printf '%s\n' "$bound_json" | jq -r '.dns_port')" "read_config_json should keep dns port for bound host"
assert_eq "192.168.70.1#7874" "$(printf '%s\n' "$bound_json" | jq -r '.mihomo_dns_listen')" "read_config_json should preserve non-loopback dns.listen host"
assert_eq "0" "$(printf '%s\n' "$bound_json" | jq -r '.errors | length')" "read_config_json should accept valid bound host"

cat > "$CLASH_CONFIG" <<'EOF'
# parser should keep quoted scalars intact and ignore unrelated nested dns keys
external-ui-name: "meta cube"
external-controller: "127.0.0.1:9090#frag"
external-ui: "./ui bundle"
secret: "abc#123"
routing-mark: 100
tproxy-port: "7894"

dns:
  fake-ip-filter:
    - "+.lan"
  listen: "0.0.0.0:5353"
  enhanced-mode: fake-ip # inline comment
  fake-ip-range: "198.18.0.0/15"
EOF

quoted_json="$(read_config_json)"

assert_eq "5353" "$(printf '%s\n' "$quoted_json" | jq -r '.dns_port')" "read_config_json should parse quoted dns.listen"
assert_eq "127.0.0.1#5353" "$(printf '%s\n' "$quoted_json" | jq -r '.mihomo_dns_listen')" "read_config_json should normalize quoted dns.listen"
assert_eq "127.0.0.1:9090#frag" "$(printf '%s\n' "$quoted_json" | jq -r '.external_controller')" "read_config_json should preserve quoted controller with hash"
assert_eq "abc#123" "$(printf '%s\n' "$quoted_json" | jq -r '.secret')" "read_config_json should preserve quoted secret with hash"
assert_eq "meta cube" "$(printf '%s\n' "$quoted_json" | jq -r '.external_ui_name')" "read_config_json should preserve spaced external UI name"
assert_eq "0" "$(printf '%s\n' "$quoted_json" | jq -r '.errors | length')" "read_config_json should ignore unrelated nested dns keys"

cat > "$CLASH_CONFIG" <<'EOF'
tproxy-port: bad
routing-mark: 4294967296

dns:
  listen: not-an-addr
  enhanced-mode: fake-ip
EOF

invalid_json="$(read_config_json)"

assert_eq "4" "$(printf '%s\n' "$invalid_json" | jq -r '.errors | length')" "read_config_json should emit expected error count"
assert_eq "true" "$(printf '%s\n' "$invalid_json" | jq -r 'any(.errors[]; contains("Invalid dns.listen"))')" "read_config_json should report invalid dns.listen"
assert_eq "true" "$(printf '%s\n' "$invalid_json" | jq -r 'any(.errors[]; contains("Invalid tproxy-port"))')" "read_config_json should report invalid tproxy-port"
assert_eq "true" "$(printf '%s\n' "$invalid_json" | jq -r 'any(.errors[]; contains("Invalid routing-mark"))')" "read_config_json should report invalid routing mark"
assert_eq "true" "$(printf '%s\n' "$invalid_json" | jq -r 'any(.errors[]; contains("Missing dns.fake-ip-range"))')" "read_config_json should report missing fake-ip range"

cat > "$CLASH_CONFIG" <<'EOF'
tproxy-port: 7894
routing-mark: 2
dns: *shared_dns
EOF

alias_json="$(read_config_json)"

assert_eq "true" "$(printf '%s\n' "$alias_json" | jq -r 'any(.errors[]; contains("Missing dns.listen"))')" "read_config_json should fail closed when dns block comes from alias"

pass "config parsing helpers"
