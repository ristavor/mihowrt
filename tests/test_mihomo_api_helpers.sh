#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/validation.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/mihomo-api.sh"

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

have_command() {
	command -v "$1" >/dev/null 2>&1
}

err() {
	:
}

assert_eq "http://127.0.0.1:9090" "$(mihomo_api_url_from_controller "0.0.0.0:9090")" "wildcard controller should map to loopback"
assert_eq "http://127.0.0.1:9090" "$(mihomo_api_url_from_controller "127.0.0.1:9090")" "loopback controller should be supported"
assert_false "empty host controller should be rejected for hot reload" mihomo_api_url_from_controller ":9090" >/dev/null
assert_false "localhost controller should be rejected for hot reload" mihomo_api_url_from_controller "http://localhost:9090" >/dev/null
assert_false "IPv6 controller should be rejected for hot reload" mihomo_api_url_from_controller "[::1]:9090" >/dev/null
assert_false "router IP controller should be rejected for hot reload" mihomo_api_url_from_controller "192.168.1.1:9090" >/dev/null
assert_false "public IP controller should be rejected for hot reload" mihomo_api_url_from_controller "1.1.1.1:9090" >/dev/null
assert_false "https controller should be unsupported for hot reload" mihomo_api_url_from_controller "https://127.0.0.1:9443" >/dev/null
assert_false "controller without port should be rejected" mihomo_api_url_from_controller "127.0.0.1" >/dev/null

pass "mihomo API helpers"
