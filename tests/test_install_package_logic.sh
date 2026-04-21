#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

apk_log="$tmpdir/apk.log"
export APK_LOG="$apk_log"

source_install_lib

apk() {
	printf '%s\n' "$*" >>"$APK_LOG"
}

log() {
	:
}

: > "$APK_LOG"
apk_supports_force_reinstall() {
	return 1
}
install_package 0 "/tmp/pkg.apk"
assert_file_contains "$APK_LOG" "add --allow-untrusted /tmp/pkg.apk" "fresh install should add package once"

: > "$APK_LOG"
apk_supports_force_reinstall() {
	return 0
}
install_package 1 "/tmp/pkg.apk"
assert_file_contains "$APK_LOG" "add --allow-untrusted --force-reinstall /tmp/pkg.apk" "reinstall should use force-reinstall when available"

: > "$APK_LOG"
apk_supports_force_reinstall() {
	return 1
}
install_package 1 "/tmp/pkg.apk"
assert_file_contains "$APK_LOG" "del $PKG_NAME" "reinstall without force support should remove old package first"
assert_file_contains "$APK_LOG" "add --allow-untrusted /tmp/pkg.apk" "reinstall without force support should add package after removal"

: > "$APK_LOG"
apk() {
	printf '%s\n' "$*" >>"$APK_LOG"
	case "$1" in
		del) return 1 ;;
		add) return 0 ;;
	esac
}
apk_supports_force_reinstall() {
	return 1
}
assert_false "install_package should fail when apk del fails" install_package 1 "/tmp/pkg.apk"
assert_file_contains "$APK_LOG" "del $PKG_NAME" "install_package should still try removing old package first"
assert_file_not_contains "$APK_LOG" "add --allow-untrusted /tmp/pkg.apk" "install_package should stop when apk del fails"

pass "installer package install branches"
