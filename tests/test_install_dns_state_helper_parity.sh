#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

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
			-e 's/\<is_valid_port_value\>/install_is_valid_port_value/g' \
			-e 's/\<dns_current_state_looks_hijacked\>/install_dns_current_state_looks_hijacked/g' \
			-e 's/^[[:space:]]//'
}

eval "$(extract_install_dns_helper dns_flatten_lines)"
eval "$(extract_install_dns_helper dns_current_servers_flat)"
eval "$(extract_install_dns_helper dnsmasq_state_matches)"
eval "$(extract_install_dns_helper is_valid_port_value)"
eval "$(extract_install_dns_helper dns_current_state_looks_hijacked)"

have_command() {
	[[ "${1:-}" == "uci" ]]
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

pass "installer dns-state helper parity"
