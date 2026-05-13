#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

source_install_lib

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns-state.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/dns.sh"

extract_install_dns_helper() {
	local function_name="$1"
	sed -n "/^[[:space:]]*${function_name}() {$/,/^[[:space:]]*}$/p" "$ROOT_DIR/install.sh" |
		sed \
			-e "1s/^[[:space:]]*${function_name}()/install_${function_name}()/" \
			-e 's/\<dns_flatten_lines\>/install_dns_flatten_lines/g' \
			-e 's/\<dns_current_servers_flat\>/install_dns_current_servers_flat/g' \
			-e 's/\<dnsmasq_state_matches\>/install_dnsmasq_state_matches/g' \
			-e 's/\<dns_backup_text_has_controls_value\>/install_dns_backup_text_has_controls_value/g' \
			-e 's/\<dns_backup_server_atom_value_valid\>/install_dns_backup_server_atom_value_valid/g' \
			-e 's/\<dns_backup_server_selector_value_valid\>/install_dns_backup_server_selector_value_valid/g' \
			-e 's/\<dns_backup_server_target_value_valid\>/install_dns_backup_server_target_value_valid/g' \
			-e 's/\<dns_backup_server_value_valid\>/install_dns_backup_server_value_valid/g' \
			-e 's/\<dns_backup_resolvfile_value_valid\>/install_dns_backup_resolvfile_value_valid/g' \
			-e 's/\<is_uint_value\>/install_is_uint_value/g' \
			-e 's/\<is_valid_port_value\>/install_is_valid_port_value/g' \
			-e 's/\<is_dns_listen_value\>/install_is_dns_listen_value/g' \
			-e 's/\<dns_current_state_looks_hijacked\>/install_dns_current_state_looks_hijacked/g' \
			-e 's/\<dns_backup_mihomo_target\>/install_dns_backup_mihomo_target/g' \
			-e 's/\<dns_backup_file_valid_for_restore\>/install_dns_backup_file_valid_for_restore/g' \
			-e 's/^[[:space:]]//'
}

eval "$(extract_install_dns_helper dns_flatten_lines)"
eval "$(extract_install_dns_helper dns_current_servers_flat)"
eval "$(extract_install_dns_helper dnsmasq_state_matches)"
eval "$(extract_install_dns_helper dns_backup_text_has_controls_value)"
eval "$(extract_install_dns_helper dns_backup_server_atom_value_valid)"
eval "$(extract_install_dns_helper dns_backup_server_selector_value_valid)"
eval "$(extract_install_dns_helper dns_backup_server_target_value_valid)"
eval "$(extract_install_dns_helper dns_backup_server_value_valid)"
eval "$(extract_install_dns_helper dns_backup_resolvfile_value_valid)"
eval "$(extract_install_dns_helper is_uint_value)"
eval "$(extract_install_dns_helper is_valid_port_value)"
eval "$(extract_install_dns_helper is_dns_listen_value)"
eval "$(extract_install_dns_helper dns_current_state_looks_hijacked)"
eval "$(extract_install_dns_helper dns_backup_mihomo_target)"
eval "$(extract_install_dns_helper dns_backup_file_valid_for_restore)"

have_command() {
	case "${1:-}" in
		uci|jq)
			return 0
			;;
	esac

	command -v "$1" >/dev/null 2>&1
}

ensure_dns_state_helpers() {
	return 0
}

uci() {
	case "${1:-} ${2:-} ${3:-}" in
		"-q get dhcp.@dnsmasq[0].cachesize")
			printf '%s\n' "${TEST_UCI_CACHESIZE:-}"
			;;
		"-q get dhcp.@dnsmasq[0].noresolv")
			printf '%s\n' "${TEST_UCI_NORESOLV:-}"
			;;
		"-q get dhcp.@dnsmasq[0].resolvfile")
			printf '%s\n' "${TEST_UCI_RESOLVFILE:-}"
			;;
		"-q get dhcp.@dnsmasq[0].server")
			printf '%b' "${TEST_UCI_SERVERS:-}"
			;;
		*)
			return 1
			;;
	esac
}

assert_eq "$(printf '1.1.1.1\n2.2.2.2\n' | dns_flatten_lines)" "$(printf '1.1.1.1\n2.2.2.2\n' | install_dns_flatten_lines)" "dns_flatten_lines should stay in sync with installer fallback"
assert_eq "$(trim '  value  ')" "$(trim_value '  value  ')" "trim_value should stay in sync with runtime trim helper"
assert_eq "$(yaml_cleanup_scalar ' "[::]:7874" # comment ')" "$(yaml_cleanup_scalar_value ' "[::]:7874" # comment ')" "yaml_cleanup_scalar_value should stay in sync with runtime scalar cleanup"
assert_eq "abc#123" "$(yaml_cleanup_scalar_value ' "abc#123" # comment ')" "yaml_cleanup_scalar_value should preserve hash inside quoted scalars"
assert_eq "$(port_from_addr '[::]:7874')" "$(port_from_addr_value '[::]:7874')" "port_from_addr_value should stay in sync with runtime port parser"
assert_eq "$(normalize_dns_server_target '0.0.0.0#7874')" "$(normalize_dns_server_target_value '0.0.0.0:7874')" "normalize_dns_server_target_value should stay in sync with runtime target normalization"
assert_true "runtime is_uint should accept integers" is_uint "123"
assert_true "installer is_uint_value should accept integers" install_is_uint_value "123"
assert_false "runtime is_uint should reject non-integers" is_uint "12x"
assert_false "installer is_uint_value should reject non-integers" install_is_uint_value "12x"
assert_false "installer is_valid_port_value should reject huge port without shell overflow" install_is_valid_port_value "999999999999999999999999"
assert_true "runtime is_dns_listen should accept host#port" is_dns_listen "127.0.0.1#7874"
assert_true "installer is_dns_listen_value should accept host#port" install_is_dns_listen_value "127.0.0.1#7874"
assert_false "runtime is_dns_listen should reject malformed targets" is_dns_listen "bad-target"
assert_false "installer is_dns_listen_value should reject malformed targets" install_is_dns_listen_value "bad-target"
assert_false "runtime is_dns_listen should reject malformed host chars" is_dns_listen "bad^server#53"
assert_false "installer is_dns_listen_value should reject malformed host chars" install_is_dns_listen_value "bad^server#53"
assert_true "runtime dns_backup_server_value_valid should accept plain upstream" dns_backup_server_value_valid "1.1.1.1"
assert_true "installer dns_backup_server_value_valid should accept plain upstream" install_dns_backup_server_value_valid "1.1.1.1"
assert_true "runtime dns_backup_server_value_valid should accept domain-specific upstream" dns_backup_server_value_valid "/#/1.1.1.1"
assert_true "installer dns_backup_server_value_valid should accept domain-specific upstream" install_dns_backup_server_value_valid "/#/1.1.1.1"
assert_false "runtime dns_backup_server_value_valid should reject invalid upstream port" dns_backup_server_value_valid "1.1.1.1#99999"
assert_false "installer dns_backup_server_value_valid should reject invalid upstream port" install_dns_backup_server_value_valid "1.1.1.1#99999"
assert_false "runtime dns_backup_server_value_valid should reject malformed plain tokens" dns_backup_server_value_valid "bad^server"
assert_false "installer dns_backup_server_value_valid should reject malformed plain tokens" install_dns_backup_server_value_valid "bad^server"
assert_false "runtime dns_backup_server_value_valid should reject malformed selector chars" dns_backup_server_value_valid "/bad^/1.1.1.1"
assert_false "installer dns_backup_server_value_valid should reject malformed selector chars" install_dns_backup_server_value_valid "/bad^/1.1.1.1"
assert_false "runtime dns_backup_server_value_valid should reject whitespace" dns_backup_server_value_valid "bad server"
assert_false "installer dns_backup_server_value_valid should reject whitespace" install_dns_backup_server_value_valid "bad server"
assert_true "runtime dns_backup_resolvfile_value_valid should accept absolute paths" dns_backup_resolvfile_value_valid "/tmp/resolv.conf"
assert_true "installer dns_backup_resolvfile_value_valid should accept absolute paths" install_dns_backup_resolvfile_value_valid "/tmp/resolv.conf"
assert_false "runtime dns_backup_resolvfile_value_valid should reject relative paths" dns_backup_resolvfile_value_valid "relative.conf"
assert_false "installer dns_backup_resolvfile_value_valid should reject relative paths" install_dns_backup_resolvfile_value_valid "relative.conf"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
CLASH_CONFIG="$tmpdir/unused-config.yaml"
cat > "$tmpdir/config.yaml" <<'EOF'
dns:
  listen: "[::]:7874" # comment
EOF
assert_eq "$(read_config_json_for_path "$tmpdir/config.yaml" | jq -r '.mihomo_dns_listen')" "$(config_mihomo_dns_target_from_path "$tmpdir/config.yaml")" "config_mihomo_dns_target_from_path should stay in sync with runtime config parser"

cat > "$tmpdir/config-bound-host-comment.yaml" <<'EOF'
dns:
  listen: "192.168.70.1:7874" # comment
EOF
assert_eq "$(read_config_json_for_path "$tmpdir/config-bound-host-comment.yaml" | jq -r '.mihomo_dns_listen')" "$(config_mihomo_dns_target_from_path "$tmpdir/config-bound-host-comment.yaml")" "config_mihomo_dns_target_from_path should parse quoted listen values with trailing comments"

cat > "$tmpdir/config-bound-host.yaml" <<'EOF'
dns:
  listen: 192.168.70.1:7874
EOF
assert_eq "$(normalize_dns_server_target_from_addr '192.168.70.1:7874')" "$(config_mihomo_dns_target_from_path "$tmpdir/config-bound-host.yaml")" "config_mihomo_dns_target_from_path should preserve bound host like runtime helper"

TEST_UCI_CACHESIZE="0"
TEST_UCI_NORESOLV="1"
TEST_UCI_RESOLVFILE=""
TEST_UCI_SERVERS=$'127.0.0.1#7874\n9.9.9.9#53\n'

assert_eq "$(dns_current_servers_flat)" "$(install_dns_current_servers_flat)" "dns_current_servers_flat should stay in sync with installer fallback"
assert_true "runtime dnsmasq_state_matches should match expected values" dnsmasq_state_matches "0" "1" "" $'127.0.0.1#7874\t9.9.9.9#53'
assert_true "installer dnsmasq_state_matches should match expected values" install_dnsmasq_state_matches "0" "1" "" $'127.0.0.1#7874\t9.9.9.9#53'
assert_false "runtime dnsmasq_state_matches should reject drift" dnsmasq_state_matches "0" "0" "" $'127.0.0.1#7874\t9.9.9.9#53'
assert_false "installer dnsmasq_state_matches should reject drift" install_dnsmasq_state_matches "0" "0" "" $'127.0.0.1#7874\t9.9.9.9#53'

TEST_UCI_SERVERS=$'127.0.0.1#7874\n'
assert_true "runtime dns_current_state_looks_hijacked should accept single Mihomo target" dns_current_state_looks_hijacked
assert_true "installer dns_current_state_looks_hijacked should accept single Mihomo target" install_dns_current_state_looks_hijacked

TEST_UCI_SERVERS=$'127.0.0.1#7874\n9.9.9.9#53\n'
assert_false "runtime dns_current_state_looks_hijacked should reject multi-server state" dns_current_state_looks_hijacked
assert_false "installer dns_current_state_looks_hijacked should reject multi-server state" install_dns_current_state_looks_hijacked

TEST_UCI_SERVERS="127.0.0.1#99999"
assert_false "runtime dns_current_state_looks_hijacked should reject invalid port" dns_current_state_looks_hijacked
assert_false "installer dns_current_state_looks_hijacked should reject invalid port" install_dns_current_state_looks_hijacked

TEST_UCI_SERVERS="1.1.1.1#54"
assert_false "runtime dns_current_state_looks_hijacked should reject unrelated external DNS target" dns_current_state_looks_hijacked
assert_false "installer dns_current_state_looks_hijacked should reject unrelated external DNS target" install_dns_current_state_looks_hijacked

cat > "$tmpdir/valid.backup" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=127.0.0.1#7874
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
assert_true "runtime dns_backup_file_valid should accept valid backup" dns_backup_file_valid "$tmpdir/valid.backup"
assert_true "installer dns_backup_file_valid_for_restore should accept valid backup" install_dns_backup_file_valid_for_restore "$tmpdir/valid.backup"
assert_eq "127.0.0.1#7874" "$(install_dns_backup_mihomo_target "$tmpdir/valid.backup")" "installer dns_backup_mihomo_target should read valid target"

cat > "$tmpdir/legacy-empty-target.backup" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
assert_true "runtime dns_backup_file_valid should treat empty target as absent metadata" dns_backup_file_valid "$tmpdir/legacy-empty-target.backup"
assert_true "installer dns_backup_file_valid_for_restore should treat empty target as absent metadata" install_dns_backup_file_valid_for_restore "$tmpdir/legacy-empty-target.backup"
assert_false "installer dns_backup_mihomo_target should reject empty target metadata" install_dns_backup_mihomo_target "$tmpdir/legacy-empty-target.backup"

cat > "$tmpdir/invalid-noresolv.backup" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=maybe
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
assert_false "runtime dns_backup_file_valid should reject invalid ORIG_NORESOLV" dns_backup_file_valid "$tmpdir/invalid-noresolv.backup"
assert_false "installer dns_backup_file_valid_for_restore should reject invalid ORIG_NORESOLV" install_dns_backup_file_valid_for_restore "$tmpdir/invalid-noresolv.backup"

cat > "$tmpdir/invalid-cachesize.backup" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=abc
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
assert_false "runtime dns_backup_file_valid should reject invalid ORIG_CACHESIZE" dns_backup_file_valid "$tmpdir/invalid-cachesize.backup"
assert_false "installer dns_backup_file_valid_for_restore should reject invalid ORIG_CACHESIZE" install_dns_backup_file_valid_for_restore "$tmpdir/invalid-cachesize.backup"

cat > "$tmpdir/invalid-target.backup" <<'EOF'
DNSMASQ_BACKUP=1
MIHOMO_DNS_TARGET=bad-target
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
EOF
assert_false "runtime dns_backup_file_valid should reject invalid MIHOMO_DNS_TARGET" dns_backup_file_valid "$tmpdir/invalid-target.backup"
assert_false "installer dns_backup_file_valid_for_restore should reject invalid MIHOMO_DNS_TARGET" install_dns_backup_file_valid_for_restore "$tmpdir/invalid-target.backup"
assert_false "installer dns_backup_mihomo_target should reject invalid target metadata" install_dns_backup_mihomo_target "$tmpdir/invalid-target.backup"

cat > "$tmpdir/invalid-server-token.backup" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=bad^server
EOF
assert_false "runtime dns_backup_file_valid should reject malformed ORIG_SERVER tokens" dns_backup_file_valid "$tmpdir/invalid-server-token.backup"
assert_false "installer dns_backup_file_valid_for_restore should reject malformed ORIG_SERVER tokens" install_dns_backup_file_valid_for_restore "$tmpdir/invalid-server-token.backup"

cat > "$tmpdir/invalid-server-selector.backup" <<'EOF'
DNSMASQ_BACKUP=1
ORIG_CACHESIZE=1000
ORIG_NORESOLV=1
ORIG_RESOLVFILE=/tmp/original.resolv
ORIG_SERVER=/bad^/1.1.1.1
EOF
assert_false "runtime dns_backup_file_valid should reject malformed ORIG_SERVER selectors" dns_backup_file_valid "$tmpdir/invalid-server-selector.backup"
assert_false "installer dns_backup_file_valid_for_restore should reject malformed ORIG_SERVER selectors" install_dns_backup_file_valid_for_restore "$tmpdir/invalid-server-selector.backup"

pass "installer dns-state helper parity"
