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
assert_eq "http://127.0.0.1:9090" "$(mihomo_api_url_from_controller ":9090")" "empty host controller should map to loopback"
assert_eq "http://127.0.0.1:9090" "$(mihomo_api_url_from_controller "http://localhost:9090")" "http localhost controller should map to loopback"
assert_eq "http://[::1]:9090" "$(mihomo_api_url_from_controller "[::1]:9090")" "IPv6 controller should be bracketed"
assert_false "https controller should be unsupported for hot reload" mihomo_api_url_from_controller "https://127.0.0.1:9443" >/dev/null
assert_false "controller without port should be rejected" mihomo_api_url_from_controller "127.0.0.1" >/dev/null

pass "mihomo API helpers"
