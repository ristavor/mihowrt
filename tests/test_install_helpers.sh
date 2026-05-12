#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "/etc/openwrt_release" ]]; then
	printf "%s\n" "${TEST_OPENWRT_RELEASE:-}"
else
	exec /bin/cat "$@"
fi
EOF

chmod +x "$tmpbin/cat"
export PATH="$tmpbin:$PATH"
export TEST_OPENWRT_RELEASE="DISTRIB_ARCH='x86_64'"
export CLASH_BIN="$tmpdir/clash"

cat > "$CLASH_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'Mihomo Meta %s\n' 'v1.19.3'
EOF
chmod +x "$CLASH_BIN"

source_install_lib

CLASH_BIN="$tmpdir/clash"

assert_eq "1.2.3" "$(normalize_version 'mihomo v1.2.3 build')" "installer normalize_version strips prefix"
assert_true "installer version_ge should accept equal versions" version_ge "1.2.3" "1.2.3"
assert_false "installer version_ge should reject older versions" version_ge "1.2.2" "1.2.3"
assert_eq "amd64" "$(detect_mihomo_arch)" "installer detect_mihomo_arch maps x86_64"
assert_eq "v1.19.3" "$(current_mihomo_version)" "installer current_mihomo_version reads binary version"

release_json='{"assets":[{"browser_download_url":"https://example.com/mihomo-linux-amd64-v1.19.3.gz"}]}'
assert_eq "https://example.com/mihomo-linux-amd64-v1.19.3.gz" "$(kernel_asset_url "$release_json" "mihomo-linux-amd64-v1.19.3.gz")" "kernel_asset_url extracts matching asset"

fetch_url() {
	printf '%s\n' '{"assets":[{"browser_download_url":"https://example.com/luci-app-mihowrt-0.2.10.apk"}]}'
}
assert_eq "https://example.com/luci-app-mihowrt-0.2.10.apk" "$(latest_asset_url)" "latest_asset_url extracts APK URL"
source_install_lib
CLASH_BIN="$tmpdir/clash"

fetch_error_log="$tmpdir/fetch.err"
err() {
	printf '%s\n' "$*" >>"$fetch_error_log"
}
have_command() {
	[[ "$1" == "wget" ]]
}
wget() {
	return 1
}
assert_false "fetch_url should fail when transfer fails with available fetcher" fetch_url "https://example.com/fail" >/dev/null 2>&1
assert_file_contains "$fetch_error_log" "failed to fetch https://example.com/fail" "fetch_url should report transfer failure separately from missing tools"

: > "$fetch_error_log"
have_command() {
	return 1
}
assert_false "download_file should fail without any fetcher" download_file "https://example.com/fail" "$tmpdir/out.bin"
assert_file_contains "$fetch_error_log" "need wget or curl" "download_file should report missing fetcher tools"

network_log="$tmpdir/network.log"
FETCH_RETRIES=7
FETCH_CONNECT_TIMEOUT=11
FETCH_MAX_TIME=22
have_command() {
	[[ "$1" == "wget" ]]
}
wget() {
	printf 'wget:%s\n' "$*" >>"$network_log"
	case "$*" in
		*' -O - '*)
			printf 'payload'
			;;
		*)
			printf 'payload' > "${@: -2:1}"
			;;
	esac
}
: > "$network_log"
assert_eq "payload" "$(fetch_url "https://example.com/ok")" "fetch_url should return wget output"
assert_file_contains "$network_log" "-T 11" "fetch_url should bound wget network timeout"
assert_file_not_contains "$network_log" "-t " "fetch_url should avoid wget retry flag unsupported by BusyBox"

: > "$network_log"
download_file "https://example.com/file" "$tmpdir/out.bin"
assert_file_contains "$tmpdir/out.bin" "payload" "download_file should move successful temporary download into target"
assert_file_contains "$network_log" "-T 11" "download_file should bound wget network timeout"
assert_file_not_contains "$network_log" "-t " "download_file should avoid wget retry flag unsupported by BusyBox"

FETCH_RETRIES=3
wget_attempts=0
wget() {
	wget_attempts=$((wget_attempts + 1))
	printf 'wget:%s\n' "$*" >>"$network_log"
	[ "$wget_attempts" -lt 3 ] && return 1
	printf 'payload' > "${@: -2:1}"
}
: > "$network_log"
assert_eq "payload" "$(fetch_url "https://example.com/retry")" "fetch_url should retry wget failures in shell"
assert_eq "3" "$(grep -c '^wget:' "$network_log")" "fetch_url should honor FETCH_RETRIES without wget -t"

package_present() {
	[[ "$1" == "nftables-json" ]]
}
have_command() {
	return 1
}
assert_true "package_requirement_present should accept nftables provider variants" package_requirement_present "nftables"

package_present() {
	[[ "$1" == "jq" ]]
}
assert_true "package_requirement_present should accept ordinary package presence" package_requirement_present "jq"

package_present() {
	[[ "$1" == "uclient-fetch" ]]
}
have_command() {
	return 1
}
assert_true "package_requirement_present should accept wget provider packages" package_requirement_present "wget-any"

package_present() {
	return 1
}
have_command() {
	[[ "$1" == "wget" ]]
}
assert_true "package_requirement_present should accept preinstalled wget command" package_requirement_present "wget-any"

package_requirement_present() {
	[[ "$1" == "pkg1" ]]
}
REQUIRED_APK_PACKAGES="pkg1 pkg2 pkg3"
assert_false "verify_required_packages should fail when packages are missing" verify_required_packages
assert_eq "pkg2 pkg3" "$MISSING_PACKAGES" "verify_required_packages should list missing packages"

MIHOWRT_ACTION="kernel"
assert_eq "kernel" "$(resolve_action)" "resolve_action should honor explicit env action"
MIHOWRT_ACTION="remove"
assert_eq "remove" "$(resolve_action)" "resolve_action should map remove action"
MIHOWRT_ACTION="stop"
assert_eq "stop" "$(resolve_action)" "resolve_action should map stop action"

unset MIHOWRT_ACTION
MIHOWRT_FORCE_REINSTALL="1"
assert_eq "package" "$(resolve_action)" "resolve_action should use force reinstall without tty"

MIHOWRT_FORCE_REINSTALL="0"
can_prompt() {
	return 1
}
assert_false "resolve_action should fail without tty and without explicit action" resolve_action >/dev/null 2>&1

MIHOWRT_ACTION="bogus"
assert_false "resolve_action should reject invalid actions" resolve_action >/dev/null 2>&1

rm_log="$tmpdir/rm.log"
rm() {
	printf '%s\n' "$*" >>"$rm_log"
	return 0
}
rmdir() {
	printf 'rmdir %s\n' "$*" >>"$rm_log"
	return 0
}
: > "$rm_log"
remove_user_state
assert_file_contains "$rm_log" "-f /opt/clash/lst/direct_dst.txt" "remove_user_state should remove direct destination list"
assert_file_contains "$rm_log" "-rf /opt/clash/ruleset" "remove_user_state should remove ruleset directory safely"
assert_file_contains "$rm_log" "-rf /opt/clash/proxy_providers" "remove_user_state should remove provider directory safely"
assert_file_not_contains "$rm_log" "-f /opt/clash/ruleset" "remove_user_state should not use rm -f for ruleset directory"
assert_file_not_contains "$rm_log" "-f /opt/clash/proxy_providers" "remove_user_state should not use rm -f for provider directory"

dns_warn_log="$tmpdir/dns.warn.log"
DNSMASQ_INIT_SCRIPT="$tmpdir/dnsmasq.init"
cat > "$DNSMASQ_INIT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
exit "${TEST_DNSMASQ_RC:-0}"
EOF
chmod +x "$DNSMASQ_INIT_SCRIPT"

warn() {
	printf '%s\n' "$*" >>"$dns_warn_log"
}

: > "$dns_warn_log"
export TEST_DNSMASQ_RC=1
assert_false "restart_dnsmasq should fail when dnsmasq restart fails" restart_dnsmasq
assert_file_contains "$dns_warn_log" "dnsmasq restart failed" "restart_dnsmasq should warn on restart failure"

: > "$dns_warn_log"
export TEST_DNSMASQ_RC=0
assert_true "restart_dnsmasq should succeed when dnsmasq restart succeeds" restart_dnsmasq
[[ ! -s "$dns_warn_log" ]] || fail "restart_dnsmasq should not warn on successful restart"

pass "installer helper logic"
