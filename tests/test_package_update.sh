#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat >"$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmpbin/apk" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_APK_LOG"

case "${1:-}" in
	list)
		if [[ "${2:-}" == "-I" ]]; then
			version="$(cat "$TEST_APK_VERSION_FILE")"
			printf '%s-%s installed\n' "${3:-luci-app-mihowrt}" "$version"
			exit 0
		fi
		;;
	add)
		if [[ "${TEST_APK_ADD_RC:-0}" != "0" ]]; then
			exit "$TEST_APK_ADD_RC"
		fi
		printf '%s\n' "${TEST_APK_NEW_VERSION:-0.7.8-r1}" >"$TEST_APK_VERSION_FILE"
		exit 0
		;;
esac

exit 1
EOF

chmod +x "$tmpbin/logger" "$tmpbin/apk"
export PATH="$tmpbin:$PATH"

apk_log="$tmpdir/apk.log"
fetch_log="$tmpdir/fetch.log"
init_log="$tmpdir/init.log"
version_file="$tmpdir/apk.version"
service_state_file="$tmpdir/service.state"
init_script="$tmpdir/mihowrt-init"

cat >"$init_script" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_INIT_LOG"

case "${1:-}" in
	running)
		[[ "$(cat "$TEST_SERVICE_STATE_FILE")" == "running" ]]
		;;
	stop)
		printf 'stopped\n' >"$TEST_SERVICE_STATE_FILE"
		;;
	start)
		printf 'running\n' >"$TEST_SERVICE_STATE_FILE"
		;;
	*)
		exit 1
		;;
esac
EOF
chmod +x "$init_script"

export TEST_APK_LOG="$apk_log"
export TEST_APK_VERSION_FILE="$version_file"
export TEST_INIT_LOG="$init_log"
export TEST_SERVICE_STATE_FILE="$service_state_file"
export PKG_STATE_DIR="$tmpdir/run"
export MIHOWRT_INIT_SCRIPT="$init_script"
export MIHOWRT_PACKAGE_NAME="luci-app-mihowrt"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

fetch_http_body_limited_to_file() {
	local url="$1" output="$5" label="$4"

	printf '%s:%s:%s\n' "$label" "$url" "$output" >>"$fetch_log"
	case "$label" in
	"package release metadata")
		if [[ "${TEST_RELEASE_FETCH_RC:-0}" != "0" ]]; then
			FETCH_HTTP_ERROR_MESSAGE="release failed"
			return "$TEST_RELEASE_FETCH_RC"
		fi
		release_tag="${TEST_RELEASE_TAG_VERSION:-${TEST_RELEASE_VERSION:-0.7.8}}"
		release_apk="${TEST_RELEASE_APK_VERSION:-${TEST_RELEASE_VERSION:-0.7.8}-r1}"
		release_asset_url="${TEST_RELEASE_ASSET_URL:-https://example.com/luci-app-mihowrt-${release_apk}.apk}"
		cat >"$output" <<EOF
{"tag_name":"v${release_tag}","assets":[{"browser_download_url":"${release_asset_url}"}]}
EOF
		;;
	"package update")
		if [[ "${TEST_APK_FETCH_RC:-0}" != "0" ]]; then
			FETCH_HTTP_ERROR_MESSAGE="apk download failed"
			return "$TEST_APK_FETCH_RC"
		fi
		printf 'apk payload\n' >"$output"
		;;
	*)
		return 1
		;;
	esac
}

reset_state() {
	rm -rf "$PKG_STATE_DIR"
	mkdir -p "$PKG_STATE_DIR"
	: >"$apk_log"
	: >"$fetch_log"
	: >"$init_log"
	printf '0.7.7-r1\n' >"$version_file"
	printf 'running\n' >"$service_state_file"
	unset TEST_RELEASE_FETCH_RC TEST_APK_FETCH_RC TEST_APK_ADD_RC TEST_RELEASE_VERSION TEST_RELEASE_TAG_VERSION TEST_RELEASE_APK_VERSION TEST_RELEASE_ASSET_URL TEST_APK_NEW_VERSION
}

reset_state
idle_json="$(package_update_status_json)"
assert_eq "idle" "$(printf '%s\n' "$idle_json" | jq -r '.status')" "package_update_status_json should default to idle"
assert_eq "0.7.7-r1" "$(printf '%s\n' "$idle_json" | jq -r '.current_version')" "package_update_status_json should include installed package version"

reset_state
TEST_RELEASE_VERSION="0.7.7"
package_update_worker
already_json="$(package_update_status_json)"
assert_eq "already_current" "$(printf '%s\n' "$already_json" | jq -r '.status')" "package_update_worker should skip install when package is current"
assert_file_not_contains "$apk_log" "add --allow-untrusted" "package_update_worker should not reinstall current package"
assert_file_not_contains "$init_log" "stop" "package_update_worker should not stop service for no-op update"

reset_state
TEST_RELEASE_VERSION="0.7.8"
export TEST_APK_NEW_VERSION="0.7.8-r1"
package_update_worker
success_json="$(package_update_status_json)"
assert_eq "success" "$(printf '%s\n' "$success_json" | jq -r '.status')" "package_update_worker should store successful update state"
assert_eq "0.7.8-r1" "$(printf '%s\n' "$success_json" | jq -r '.current_version')" "package_update_worker should refresh installed version after update"
assert_file_contains "$fetch_log" "package release metadata:" "package_update_worker should query latest release"
assert_file_contains "$fetch_log" "package update:https://example.com/luci-app-mihowrt-0.7.8-r1.apk" "package_update_worker should download selected package asset to tmp"
assert_file_contains "$apk_log" "add --allow-untrusted" "package_update_worker should install downloaded APK"
assert_file_contains "$init_log" "stop" "package_update_worker should stop running service before update"
assert_file_contains "$init_log" "start" "package_update_worker should restore running service after update"

reset_state
printf '0.7.8-r1\n' >"$version_file"
TEST_RELEASE_TAG_VERSION="0.7.8"
TEST_RELEASE_APK_VERSION="0.7.8-r2"
export TEST_APK_NEW_VERSION="0.7.8-r2"
package_update_worker
release_bump_json="$(package_update_status_json)"
assert_eq "success" "$(printf '%s\n' "$release_bump_json" | jq -r '.status')" "package_update_worker should update when APK release suffix increases"
assert_eq "0.7.8-r2" "$(printf '%s\n' "$release_bump_json" | jq -r '.current_version')" "package_update_worker should refresh installed APK release suffix"
assert_eq "0.7.8-r2" "$(printf '%s\n' "$release_bump_json" | jq -r '.latest_version')" "package_update_worker should preserve APK release suffix in latest version"
assert_file_contains "$apk_log" "add --allow-untrusted" "package_update_worker should install package when only release suffix changed"

reset_state
TEST_RELEASE_VERSION="0.7.8"
export TEST_APK_ADD_RC=1
assert_false "package_update_worker should fail when apk add fails" package_update_worker
apk_failed_json="$(package_update_status_json)"
assert_eq "error" "$(printf '%s\n' "$apk_failed_json" | jq -r '.status')" "package_update_worker should persist apk install failure state"
assert_eq "running" "$(cat "$service_state_file")" "package_update_worker should restore service after install failure"
assert_file_contains "$init_log" "start" "package_update_worker should attempt service restore after install failure"

reset_state
TEST_RELEASE_VERSION="0.7.8"
TEST_APK_FETCH_RC=1
assert_false "package_update_worker should fail when APK download fails" package_update_worker
failed_json="$(package_update_status_json)"
assert_eq "error" "$(printf '%s\n' "$failed_json" | jq -r '.status')" "package_update_worker should persist download failure state"
assert_eq "apk download failed" "$(printf '%s\n' "$failed_json" | jq -r '.message')" "package_update_worker should expose fetch failure message"
assert_file_not_contains "$apk_log" "add --allow-untrusted" "package_update_worker should not install after download failure"

reset_state
TEST_RELEASE_ASSET_URL="https://example.com/other-package-0.7.8-r1.apk"
assert_false "package_update_worker should fail when package asset is missing" package_update_worker
missing_asset_json="$(package_update_status_json)"
assert_eq "error" "$(printf '%s\n' "$missing_asset_json" | jq -r '.status')" "package_update_worker should persist missing asset failure state"
assert_eq "Failed to find latest package APK in GitHub release" "$(printf '%s\n' "$missing_asset_json" | jq -r '.message')" "package_update_worker should explain missing package asset"
assert_file_not_contains "$apk_log" "add --allow-untrusted" "package_update_worker should not install when package asset is missing"

reset_state
package_update_store_state running 999999 "0.7.7-r1" "0.7.8" "https://example.com/pkg.apk" "Installing"
stale_json="$(package_update_status_json)"
assert_eq "error" "$(printf '%s\n' "$stale_json" | jq -r '.status')" "package_update_status_json should mark stale running state as failed"
assert_eq "Package update interrupted" "$(printf '%s\n' "$stale_json" | jq -r '.message')" "package_update_status_json should explain interrupted update"

pass "package update helpers"
