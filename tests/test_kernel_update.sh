#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat >"$tmpbin/cat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "/etc/openwrt_release" ]]; then
	printf "%s\n" "${TEST_OPENWRT_RELEASE:-}"
else
	exec /bin/cat "$@"
fi
EOF

cat >"$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$tmpbin/cat" "$tmpbin/logger"
export PATH="$tmpbin:$PATH"
export TEST_OPENWRT_RELEASE="DISTRIB_ARCH='x86_64'"

export CLASH_BIN="$tmpdir/opt/clash/bin/clash"
export KERNEL_TMP_DIR="$tmpdir/tmp/kernel-update"
export KERNEL_FETCH_TIMEOUT=3
mkdir -p "${CLASH_BIN%/*}"

write_kernel_script() {
	local path="$1"
	local version="$2"

	cat >"$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-v" ]]; then
	printf 'Mihomo Meta v%s\n' '$version'
fi
EOF
	chmod +x "$path"
}

write_kernel_script "$CLASH_BIN" "1.19.26"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
mihowrt_source_module kernel.sh

service_running_state() {
	return "${TEST_SERVICE_RUNNING_RC:-1}"
}

fetch_http_body_limited() {
	printf '%s\n' "$TEST_RELEASE_JSON"
}

fetch_http_body_limited_to_file() {
	printf '%s\n' "$5" >>"$TEST_FETCH_OUTPUT_LOG"
	cp "$TEST_ASSET_GZ" "$5"
}

asset_script="$tmpdir/asset-clash"
asset_gz="$tmpdir/asset-clash.gz"
TEST_ASSET_GZ="$asset_gz"
TEST_FETCH_OUTPUT_LOG="$tmpdir/fetch-output.log"
export TEST_ASSET_GZ TEST_FETCH_OUTPUT_LOG

write_kernel_script "$asset_script" "1.19.26"
gzip -c "$asset_script" >"$asset_gz"
TEST_RELEASE_JSON='{"tag_name":"v1.19.26","assets":[{"name":"mihomo-linux-amd64-compatible-v1.19.26.gz","browser_download_url":"https://example.com/mihomo-linux-amd64-compatible-v1.19.26.gz"}]}'

up_to_date_json="$(kernel_update_json)"
assert_eq "up_to_date" "$(printf '%s\n' "$up_to_date_json" | jq -r '.action')" "kernel_update_json should skip current kernels"
assert_eq "false" "$(printf '%s\n' "$up_to_date_json" | jq -r '.updated')" "kernel_update_json should report no update when current"
[[ ! -e "$TEST_FETCH_OUTPUT_LOG" ]] || fail "kernel_update_json should not download when version is current"

write_kernel_script "$CLASH_BIN" "1.19.24"
write_kernel_script "$asset_script" "1.19.26"
gzip -c "$asset_script" >"$asset_gz"
: >"$TEST_FETCH_OUTPUT_LOG"
TEST_SERVICE_RUNNING_RC=0
update_json="$(kernel_update_json)"
assert_eq "updated" "$(printf '%s\n' "$update_json" | jq -r '.action')" "kernel_update_json should install newer kernel"
assert_eq "true" "$(printf '%s\n' "$update_json" | jq -r '.updated')" "kernel_update_json should report updated=true"
assert_eq "true" "$(printf '%s\n' "$update_json" | jq -r '.restart_required')" "kernel_update_json should report restart required when service is running"
assert_eq "amd64" "$(printf '%s\n' "$update_json" | jq -r '.arch')" "kernel_update_json should expose detected arch"
assert_eq "mihomo-linux-amd64-compatible-v1.19.26.gz" "$(printf '%s\n' "$update_json" | jq -r '.asset')" "kernel_update_json should prefer compatible amd64 asset"
assert_eq "v1.19.26" "$(current_mihomo_version)" "kernel_update_json should replace installed kernel"
assert_file_contains "$TEST_FETCH_OUTPUT_LOG" "$KERNEL_TMP_DIR/mihomo-linux-amd64-compatible-v1.19.26.gz" "kernel_update_json should download asset into tmpfs staging"
[[ ! -d "$KERNEL_TMP_DIR" ]] || fail "kernel_update_json should clean tmpfs staging after success"

write_kernel_script "$CLASH_BIN" "1.19.24"
write_kernel_script "$asset_script" "1.19.24"
gzip -c "$asset_script" >"$asset_gz"
TEST_RELEASE_JSON='{"tag_name":"v1.19.26","assets":[{"name":"mihomo-linux-amd64-compatible-v1.19.26.gz","browser_download_url":"https://example.com/mihomo-linux-amd64-compatible-v1.19.26.gz"}]}'
TEST_SERVICE_RUNNING_RC=1
unchanged_json="$(kernel_update_json)"
assert_eq "unchanged" "$(printf '%s\n' "$unchanged_json" | jq -r '.action')" "kernel_update_json should skip identical downloaded binaries"
assert_eq "false" "$(printf '%s\n' "$unchanged_json" | jq -r '.updated')" "kernel_update_json should report unchanged identical binary"
assert_eq "v1.19.24" "$(current_mihomo_version)" "kernel_update_json should keep identical kernel"
[[ ! -d "$KERNEL_TMP_DIR" ]] || fail "kernel_update_json should clean tmpfs staging after identical binary skip"

TEST_RELEASE_JSON='{"tag_name":"v1.19.27","assets":[{"name":"mihomo-linux-arm64-v1.19.27.gz","browser_download_url":"https://example.com/mihomo-linux-arm64-v1.19.27.gz"}]}'
if kernel_update_json >/dev/null 2>&1; then
	fail "kernel_update_json should fail when no matching architecture asset exists"
fi

pass "runtime kernel update helper"
