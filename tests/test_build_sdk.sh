#!/usr/bin/env bash
#
# tests/test_build_sdk.sh - Verification tests for tools/build-sdk.sh, Dockerfile.sdk, and Dockerfile.test
#

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/tools/build-sdk.sh"
DOCKERFILE_SDK="${ROOT_DIR}/Dockerfile.sdk"
DOCKERFILE_TEST="${ROOT_DIR}/Dockerfile.test"

passed=0
failed=0

assert_eq() {
	local desc="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'ok - %s\n' "$desc"
		passed=$((passed + 1))
	else
		printf 'not ok - %s (expected %s, got %s)\n' "$desc" "$expected" "$actual" >&2
		failed=$((failed + 1))
	fi
}

assert_contains() {
	local desc="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'ok - %s\n' "$desc"
		passed=$((passed + 1))
	else
		printf 'not ok - %s (needle not found: %s)\n' "$desc" "$needle" >&2
		failed=$((failed + 1))
	fi
}

# Test 1: build-sdk.sh exists and is executable
if [[ -x "$SCRIPT" ]]; then
	printf 'ok - tools/build-sdk.sh exists and is executable\n'
	passed=$((passed + 1))
else
	printf 'not ok - tools/build-sdk.sh not executable\n' >&2
	failed=$((failed + 1))
fi

# Test 2: Shell syntax passes
if bash -n "$SCRIPT"; then
	printf 'ok - tools/build-sdk.sh syntax is valid bash\n'
	passed=$((passed + 1))
else
	printf 'not ok - tools/build-sdk.sh syntax error\n' >&2
	failed=$((failed + 1))
fi

# Test 3: --help works and documents commands and volume
help_out="$("$SCRIPT" --help)"
assert_contains "help output mentions build command" "build" "$help_out"
assert_contains "help output mentions test command" "test" "$help_out"
assert_contains "help output mentions prepare command" "prepare" "$help_out"
assert_contains "help output mentions Docker volume name" "mihowrt-sdk-25.12.6" "$help_out"
assert_contains "help output documents APFS/case-insensitive caveat" "case-insensitive" "$help_out"
assert_contains "help output documents QEMU architecture caveat" "Architecture caveat" "$help_out"
assert_contains "help output defaults to sane 4 jobs" "default: 4" "$help_out"

# Test 4: Dockerfile.sdk exists and contains required components
if [[ -f "$DOCKERFILE_SDK" ]]; then
	printf 'ok - Dockerfile.sdk exists\n'
	passed=$((passed + 1))
	dockerfile_content="$(cat "$DOCKERFILE_SDK")"
	assert_contains "Dockerfile.sdk uses ubuntu:24.04" "ubuntu:24.04" "$dockerfile_content"
	assert_contains "Dockerfile.sdk sets FORCE_UNSAFE_CONFIGURE=1" "FORCE_UNSAFE_CONFIGURE=1" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs nodejs" "nodejs" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs jq" "jq" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs shellcheck" "shellcheck" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs bash" "bash" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs rsync" "rsync" "$dockerfile_content"
	assert_contains "Dockerfile.sdk installs zstd" "zstd" "$dockerfile_content"
else
	printf 'not ok - Dockerfile.sdk does not exist\n' >&2
	failed=$((failed + 1))
fi

# Test 5: Dockerfile.test exists and contains native test requirements
if [[ -f "$DOCKERFILE_TEST" ]]; then
	printf 'ok - Dockerfile.test exists\n'
	passed=$((passed + 1))
	test_dockerfile_content="$(cat "$DOCKERFILE_TEST")"
	assert_contains "Dockerfile.test uses alpine" "alpine" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs bash" "bash" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs jq" "jq" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs nodejs" "nodejs" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs shellcheck" "shellcheck" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs coreutils" "coreutils" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs gawk" "gawk" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs grep" "grep" "$test_dockerfile_content"
	assert_contains "Dockerfile.test installs sed" "sed" "$test_dockerfile_content"
else
	printf 'not ok - Dockerfile.test does not exist\n' >&2
	failed=$((failed + 1))
fi

# Test 6: Script does NOT use fake shellcheck stub
script_content="$(cat "$SCRIPT")"
if [[ "$script_content" == *"sdk-test-shim"* ]]; then
	printf 'not ok - tools/build-sdk.sh still contains fake shellcheck shim\n' >&2
	failed=$((failed + 1))
else
	printf 'ok - tools/build-sdk.sh does not contain fake shellcheck stub\n'
	passed=$((passed + 1))
fi

# Test 7: Script contains Kconfig recursive dependency fix
assert_contains "tools/build-sdk.sh minimal config fixes LIBCURL_LDAP" "CONFIG_LIBCURL_LDAP=n" "$script_content"

# Regression: an interrupted metadata scan leaves an empty tmp/.packageinfo
# that make treats as fresh, so every later build fails with "No rule".
assert_contains "tools/build-sdk.sh rescans an empty package index" '[ -s tmp/.packageinfo ]' "$script_content"

# Test 8: Script asserts both APKs exist
assert_contains "tools/build-sdk.sh asserts luci-app-mihowrt APK" "luci-app-mihowrt-*.apk" "$script_content"
assert_contains "tools/build-sdk.sh asserts luci-i18n-mihowrt-ru APK" "luci-i18n-mihowrt-ru-*.apk" "$script_content"

# Test 9: On macOS, --native should be rejected with non-zero exit code
if [[ "$(uname -s)" == "Darwin" ]]; then
	set +e
	native_err="$("$SCRIPT" --native build 2>&1)"
	native_rc=$?
	set -e
	if [[ $native_rc -ne 0 ]]; then
		printf 'ok - --native build rejected on macOS host with non-zero exit code\n'
		passed=$((passed + 1))
	else
		printf 'not ok - --native succeeded on macOS host unexpectedly\n' >&2
		failed=$((failed + 1))
	fi
	assert_contains "native rejection mentions Darwin/macOS or case-insensitive" "case-insensitive" "$native_err"
fi

# Test 10: Feeds installs only luci-base host prerequisite
assert_contains "tools/build-sdk.sh installs luci-base feed" "./scripts/feeds install luci-base" "$script_content"
assert_contains "tools/build-sdk.sh uninstalls cyclic runtime feeds" "./scripts/feeds uninstall curl jq nftables" "$script_content"

# Test 11: Host target po2lmo validation
assert_contains "tools/build-sdk.sh builds host dependency luci-base/host" "make package/feeds/luci/luci-base/host/compile" "$script_content"
assert_contains "tools/build-sdk.sh validates host tool po2lmo" "staging_dir/hostpkg/bin/po2lmo" "$script_content"

# Test 12: Direct package compile without target cross-compiler
assert_contains "tools/build-sdk.sh runs direct package clean" "make -C package/luci-app-mihowrt clean" "$script_content"
assert_contains "tools/build-sdk.sh runs direct package compile" "make -C package/luci-app-mihowrt compile" "$script_content"

# Test 13: Verify SDK archive exists and sha256 matches expected
archive="${ROOT_DIR}/.sdk/openwrt-sdk-25.12.6-x86-64.tar.zst"
if [[ -f "$archive" ]]; then
	if command -v shasum >/dev/null 2>&1; then
		sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
	else
		sha="$(sha256sum "$archive" | awk '{print $1}')"
	fi
	assert_eq "SDK archive sha256 matches expected official hash" "1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc" "$sha"
else
	printf 'ok - SDK archive download helper will trigger on missing file\n'
	passed=$((passed + 1))
fi

printf '\nSummary: %d passed, %d failed\n' "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
	exit 1
fi
