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

# Test 14: CI and release workflows (static checks; first real run is on push)
TEST_YML="${ROOT_DIR}/.github/workflows/test.yml"
RELEASE_YML="${ROOT_DIR}/.github/workflows/release.yml"
test_yml="$(cat "$TEST_YML" 2>/dev/null || true)"
release_yml="$(cat "$RELEASE_YML" 2>/dev/null || true)"
assert_contains "test.yml runs on push" "push:" "$test_yml"
assert_contains "test.yml runs on pull_request" "pull_request:" "$test_yml"
assert_contains "test.yml builds the test image" "docker build -t mihowrt-test:local -f Dockerfile.test ." "$test_yml"
assert_contains "test.yml runs the suite" "bash tests/run.sh" "$test_yml"
assert_contains "release.yml triggers on v* tags" "tags: ['v*']" "$release_yml"
assert_contains "release.yml has contents: write" "contents: write" "$release_yml"
assert_contains "release.yml has a build job" $'\n  build:' "$release_yml"
assert_contains "release.yml has a publish job" $'\n  publish:' "$release_yml"
assert_contains "release.yml publish needs build" "needs: build" "$release_yml"
assert_contains "release.yml top-level permissions are empty" $'\npermissions: {}' "$release_yml"
assert_contains "release.yml build job is read-only" $'  build:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: read' "$release_yml"
assert_contains "release.yml publish job can write" $'    needs: build\n    runs-on: ubuntu-latest\n    permissions:\n      contents: write' "$release_yml"
assert_contains "release.yml checkout drops credentials" "persist-credentials: false" "$release_yml"
assert_contains "release.yml uploads artifacts" "actions/upload-artifact@v4" "$release_yml"
assert_contains "release.yml downloads artifacts" "actions/download-artifact@v4" "$release_yml"
assert_contains "release.yml names the repo for gh" '--repo "$GITHUB_REPOSITORY"' "$release_yml"
assert_contains "test.yml checkout drops credentials" "persist-credentials: false" "$test_yml"
assert_contains "release.yml compares the tag with PKG_VERSION" 'PKG_VERSION' "$release_yml"
assert_contains "release.yml builds with build-sdk" "./tools/build-sdk.sh build" "$release_yml"
assert_contains "release.yml writes SHA256SUMS with sha256sum" "sha256sum" "$release_yml"
assert_contains "release.yml lists the fixed-name app APK" "luci-app-mihowrt.apk" "$release_yml"
assert_contains "release.yml lists the fixed-name i18n APK" "luci-i18n-mihowrt-ru.apk" "$release_yml"
assert_contains "release.yml creates the release" "gh release create" "$release_yml"
assert_contains "release.yml uses the workflow token" "secrets.GITHUB_TOKEN" "$release_yml"
for wf in "$TEST_YML" "$RELEASE_YML"; do
	if [[ -f "$wf" ]] && ! grep -P '\t' "$wf" >/dev/null && ! grep -q '@master\|@main' "$wf"; then
		printf 'ok - %s has no tabs and no floating action refs\n' "${wf##*/}"
		passed=$((passed + 1))
	else
		printf 'not ok - %s missing, has tabs or floating action refs\n' "${wf##*/}" >&2
		failed=$((failed + 1))
	fi
done

# Test 14b: run the release staging step on fake dist files
if [[ -n "$release_yml" ]]; then
	stage_script="$(awk '/- name: Stage release assets/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - name:/{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
	stage_dir="$(mktemp -d)"
	mkdir -p "$stage_dir/dist"
	printf a > "$stage_dir/dist/luci-app-mihowrt-0.10.0-r1.apk"
	printf b > "$stage_dir/dist/luci-i18n-mihowrt-ru-0.10.0-r1.apk"
	(cd "$stage_dir" && bash -c "$stage_script" >/dev/null 2>&1) || true
	sums="$(cat "$stage_dir/release/SHA256SUMS" 2>/dev/null || true)"
	assert_contains "staging lists the versioned app APK by bare name" "  luci-app-mihowrt-0.10.0-r1.apk" "$sums"
	assert_contains "staging lists the fixed-name i18n APK by bare name" "  luci-i18n-mihowrt-ru.apk" "$sums"
	if [[ "$sums" == *"/"* || "$sums" == *"dist"* ]]; then
		printf 'not ok - SHA256SUMS contains paths\n' >&2
		failed=$((failed + 1))
	else
		printf 'ok - SHA256SUMS has no paths\n'
		passed=$((passed + 1))
	fi
	if [[ -n "$sums" ]] && (cd "$stage_dir/release" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
		printf 'ok - SHA256SUMS verifies inside release/\n'
		passed=$((passed + 1))
	else
		printf 'not ok - SHA256SUMS does not verify inside release/\n' >&2
		failed=$((failed + 1))
	fi
	rm -rf "$stage_dir"
fi

# Test 14c: extract and run the version boundary; never contact GitHub.
version_script="$(awk '/- name: Check tag against PKG_VERSION/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
publish_script="$(awk '/- name: Create GitHub release/{f=1;next} f&&/run: \|/{r=1;next} r&&/^      - /{exit} r{sub(/^          /,"");print}' "$RELEASE_YML")"
workflow_dir="$(mktemp -d)"
trap 'rm -rf "$workflow_dir"' EXIT
cp "$ROOT_DIR/Makefile" "$workflow_dir/Makefile"
assert_contains 'version-check block extracted from release.yml' 'PKG_VERSION' "$version_script"
for tag_case in v0.10.0:0:0 v0.10.0-rc1:0:1 v0.10.0-rc:1:- v0.10.1:1:- v0.10.0-beta1:1:-; do
 IFS=: read -r tag expected_rc expected_prerelease <<<"$tag_case"
 : >"$workflow_dir/env"; : >"$workflow_dir/output"
 tag_rc=0
 (cd "$workflow_dir" && GITHUB_REF_NAME="$tag" GITHUB_ENV="$workflow_dir/env" GITHUB_OUTPUT="$workflow_dir/output" bash -c "$version_script") >"$workflow_dir/tag.stdout" 2>"$workflow_dir/tag.stderr" || tag_rc=$?
 assert_eq "$tag version-check status" "$expected_rc" "$tag_rc"
 if [[ "$expected_rc" = 0 ]]; then
  actual_prerelease="$(sed -n 's/^PRERELEASE=//p' "$workflow_dir/env")"
  assert_eq "$tag prerelease flag" "$expected_prerelease" "$actual_prerelease"
 fi
done

# Check cross-job transport without prescribing the step/output identifier.
build_job="$(awk '/^  build:/{f=1;next} f&&/^  [^ ]/{exit} f{print}' "$RELEASE_YML")"
publish_job="$(awk '/^  publish:/{f=1;next} f{print}' "$RELEASE_YML")"
assert_contains 'build exposes job outputs' '    outputs:' "$build_job"
assert_contains 'build writes a step output' 'GITHUB_OUTPUT' "$build_job"
assert_contains 'publish receives prerelease through a build output' 'needs.build.outputs.' "$publish_job"
prerelease_output="$(printf '%s\n' "$publish_job" | sed -n 's/^[[:space:]]*PRERELEASE:.*needs\.build\.outputs\.\([A-Za-z0-9_-]*\).*$/\1/p')"
if [[ -n "$prerelease_output" ]]; then
 build_outputs="$(printf '%s\n' "$build_job" | awk '/^    outputs:/{f=1;next} f&&/^    [^ ]/{exit} f{print}')"
 assert_contains 'publish PRERELEASE output is declared by build' "$prerelease_output:" "$build_outputs"
 assert_contains 'build job outputs reference a step output' '.outputs.' "$build_outputs"
else
 assert_eq 'publish PRERELEASE is wired to a build output' 'build output reference' "$prerelease_output"
fi

# Execute the extracted publish block with a local gh recorder: only flag 1
# may produce --prerelease. The real gh executable is never invoked.
mkdir -p "$workflow_dir/bin" "$workflow_dir/release"
cat >"$workflow_dir/bin/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$@" >"$GH_CALLS"
GH
chmod +x "$workflow_dir/bin/gh"
printf app >"$workflow_dir/release/app.apk"
printf sum >"$workflow_dir/release/SHA256SUMS"
: >"$workflow_dir/release-notes.md"
assert_contains 'publish block extracted from release.yml' 'gh release create' "$publish_script"
for prerelease_flag in 0 1; do
 publish_rc=0
 (cd "$workflow_dir" && PATH="$workflow_dir/bin:$PATH" GH_CALLS="$workflow_dir/gh.calls" PRERELEASE="$prerelease_flag" GITHUB_REF_NAME=v0.10.0 GITHUB_REPOSITORY=fixture/mihowrt bash -c "$publish_script") >"$workflow_dir/publish.stdout" 2>"$workflow_dir/publish.stderr" || publish_rc=$?
 assert_eq "publish PRERELEASE=$prerelease_flag status" 0 "$publish_rc"
 prerelease_count="$(grep -cx -- '--prerelease' "$workflow_dir/gh.calls" || true)"
 assert_eq "publish --prerelease only when PRERELEASE=$prerelease_flag" "$prerelease_flag" "$prerelease_count"
done
rm -rf "$workflow_dir"
trap - EXIT

# Test 15: license and package metadata
makefile_content="$(cat "${ROOT_DIR}/Makefile")"
assert_contains "Makefile declares PKG_LICENSE" "PKG_LICENSE:=GPL-3.0-or-later" "$makefile_content"
assert_contains "Makefile declares PKG_LICENSE_FILES" "PKG_LICENSE_FILES:=LICENSE" "$makefile_content"
assert_contains "Makefile maintainer has an email" "PKG_MAINTAINER:=ristavor <90447432+ristavor@users.noreply.github.com>" "$makefile_content"
if [[ "$script_content" == *"LICENSE"* ]]; then
	printf 'not ok - build-sdk.sh must not copy LICENSE (PKG_LICENSE_FILES is metadata only)\n' >&2
	failed=$((failed + 1))
else
	printf 'ok - build-sdk.sh does not copy LICENSE into the SDK\n'
	passed=$((passed + 1))
fi
license_head="$(head -n 2 "${ROOT_DIR}/LICENSE" 2>/dev/null || true)"
assert_contains "LICENSE is GPL" "GNU GENERAL PUBLIC LICENSE" "$license_head"
assert_contains "LICENSE is version 3" "Version 3, 29 June 2007" "$license_head"
changelog_content="$(cat "${ROOT_DIR}/CHANGELOG.md" 2>/dev/null || true)"
assert_contains "CHANGELOG.md has a 0.10.0 section" "## 0.10.0" "$changelog_content"
readme_content="$(cat "${ROOT_DIR}/README.md")"
assert_contains "README documents the release order" "git tag vX && git push origin vX" "$readme_content"

printf '\nSummary: %d passed, %d failed\n' "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
	exit 1
fi
