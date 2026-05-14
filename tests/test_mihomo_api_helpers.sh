#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

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

require_command() {
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
assert_eq "/opt/clash/mihomo.sock" "$(mihomo_api_socket_path "mihomo.sock")" "relative Unix socket should resolve under Clash dir"
assert_eq "/tmp/mihomo.sock" "$(mihomo_api_socket_path "/tmp/mihomo.sock")" "absolute Unix socket should stay absolute"
assert_false "URL-like Unix socket should be rejected" mihomo_api_socket_path "unix://mihomo.sock" >/dev/null

MIHOMO_API_LIVE_STATE_FILE="$tmpdir/live-api.json"
live_input='{"external_controller":"0.0.0.0:9090","external_controller_unix":"mihomo.sock","secret":"top-secret","external_controller_cors":"external-controller-cors:\n  allow-private-network: true","external_ui_url":"https://example.com/ui.zip","dns_port":"7874"}'
assert_true "live API state should be saved from config metadata" mihomo_api_live_state_save "$live_input"
assert_eq "mihomo.sock" "$(mihomo_api_live_state_read | jq -r '.external_controller_unix')" "live API state should preserve Unix socket"
assert_eq "top-secret" "$(mihomo_api_live_state_read | jq -r '.secret')" "live API state should preserve secret"
assert_eq "https://example.com/ui.zip" "$(mihomo_api_live_state_read | jq -r '.external_ui_url')" "live API state should preserve external UI URL"
assert_eq "null" "$(mihomo_api_live_state_read | jq -r '.dns_port')" "live API state should omit non-API runtime fields"
assert_eq "mihomo.sock" "$(mihomo_api_live_or_config_json '{"external_controller":"127.0.0.1:9091","external_controller_unix":"new.sock"}' | jq -r '.external_controller_unix')" "live API state should win over saved config metadata"
mihomo_api_live_state_clear
assert_false "live API state clear should remove persisted endpoint" test -e "$MIHOMO_API_LIVE_STATE_FILE"

fake_bin="$tmpdir/bin"
curl_log="$tmpdir/curl.args"
mkdir -p "$fake_bin"
cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_CURL_ARGS_LOG"
printf '204'
FAKE_CURL
chmod +x "$fake_bin/curl"

old_path="$PATH"
PATH="$fake_bin:$PATH"
export PATH
export TEST_CURL_ARGS_LOG="$curl_log"
assert_true "hot reload should work with Mihomo secret" \
	mihomo_hot_reload_config '{"external_controller":"0.0.0.0:9090","secret":"top-secret"}' "/opt/clash/config.yaml"

assert_file_contains "$curl_log" "Authorization: Bearer top-secret" "hot reload should send bearer token from config"
assert_file_contains "$curl_log" "http://127.0.0.1:9090/configs?force=false" "hot reload should default to non-forced loopback API"

: >"$curl_log"
assert_true "hot reload should force Mihomo reload when requested" \
	mihomo_hot_reload_config '{"external_controller":"0.0.0.0:9090","secret":"top-secret"}' "/opt/clash/config.yaml" 1
assert_file_contains "$curl_log" "http://127.0.0.1:9090/configs?force=true" "hot reload should pass force=true only when requested"

: >"$curl_log"
assert_true "hot reload should prefer Mihomo Unix socket over IP controller" \
	mihomo_hot_reload_config '{"external_controller":"1.1.1.1:9090","external_controller_unix":"mihomo.sock","secret":"top-secret"}' "/opt/clash/config.yaml"
assert_file_contains "$curl_log" "--unix-socket" "hot reload should pass Unix socket to curl"
assert_file_contains "$curl_log" "/opt/clash/mihomo.sock" "hot reload should resolve relative Unix socket through Clash dir"
assert_file_contains "$curl_log" "http://127.0.0.1/configs?force=false" "Unix socket hot reload should use local HTTP URL"
assert_file_not_contains "$curl_log" "1.1.1.1" "Unix socket hot reload should not call configured IP controller"

assert_false "hot reload should require either Unix socket or safe IP controller" \
	mihomo_hot_reload_config '{"external_controller":"","external_controller_unix":"","secret":""}' "/opt/clash/config.yaml"
PATH="$old_path"
unset TEST_CURL_ARGS_LOG

pass "mihomo API helpers"
