#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

set +u
source_install_lib
set -u
can_prompt() { return 1; }

installed=""
package_installed() { [[ " $installed " == *" $1 "* ]]; }

assert_eq install "$(MIHOWRT_ACTION=update resolve_action)" "update is install"
assert_eq remove "$(MIHOWRT_ACTION=uninstall resolve_action)" "uninstall is remove"
if (MIHOWRT_ACTION=bogus resolve_action) >/dev/null 2>&1; then fail "invalid action must fail"; fi
if (resolve_action) >/dev/null 2>&1; then fail "no tty and no action must fail"; fi
pass "action selection"

assert_eq en "$(resolve_language)" "fresh non-interactive install is English"
installed="luci-app-mihowrt luci-i18n-mihowrt-ru"
assert_eq ru "$(resolve_language)" "update keeps Russian"
installed="luci-app-mihowrt"
assert_eq en "$(resolve_language)" "update keeps English"
assert_eq ru "$(MIHOWRT_LANGUAGE=RU resolve_language)" "explicit language wins"
if (MIHOWRT_LANGUAGE=de resolve_language) >/dev/null 2>&1; then fail "unsupported language must fail"; fi
pass "language preserved"

CORE="$tmpdir/clash"
free_kb() { echo 40960; }
if (check_space) >/dev/null 2>&1; then fail "40 MiB is not enough without a core"; fi
touch "$CORE"
chmod +x "$CORE"
(check_space) || fail "40 MiB is enough when the core exists"
pass "space check"

calls="$tmpdir/calls"
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$calls" >"$tmpdir/bin/apk"
chmod +x "$tmpdir/bin/apk"
PATH="$tmpdir/bin:$PATH"
installed="luci-app-mihowrt luci-i18n-mihowrt-ru"
(MIHOWRT_ACTION=remove main) >/dev/null
assert_eq $'apk del luci-i18n-mihowrt-ru\napk del luci-app-mihowrt' "$(cat "$calls")" "translation removed before the app"
[[ -e "$CORE" ]] || fail "installer must leave core cleanup to prerm"
pass "remove"

# Installer: fixed asset names from releases/latest, verified by SHA256SUMS.
BASE="https://github.com/ristavor/mihowrt/releases/latest/download"
check_space() { :; }
apk_log="$tmpdir/apk.log"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$apk_log" >"$tmpdir/bin/apk"
installed=""
fake_release() { # fake_release <sums-mode: ok|bad|missing|404>
	SUMS_MODE="$1"
	RU_MODE="${2:-ok}"
	rm -f "$tmpdir/downloads" "$apk_log"
	WORK="$tmpdir/work.$RANDOM"
	mkdir -p "$WORK"
}
curl() {
	local out="" prev="" a url=""
	for a in "$@"; do
		[ "$prev" = "-o" ] && out="$a"
		prev="$a"
		url="$a"
	done
	echo "$url" >>"$tmpdir/downloads"
	case "$url" in
	*/SHA256SUMS)
		[ "$SUMS_MODE" = 404 ] && return 22
		app="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
		ru="$(printf 'ru-bytes' | sha256sum | cut -d' ' -f1)"
		[ "$RU_MODE" = bad ] && ru="$(printf 'ru-byteX' | sha256sum | cut -d' ' -f1)"
		[ "$SUMS_MODE" = bad ] && app="$(printf 'app-byteX' | sha256sum | cut -d' ' -f1)"
		{
			[ "$SUMS_MODE" = missing ] || printf '%s  luci-app-mihowrt-0.10.0-r1.apk\n%s  luci-app-mihowrt.apk\n' "$app" "$app"
			[ "$RU_MODE" = missing ] || printf '%s  luci-i18n-mihowrt-ru-0.10.0-r1.apk\n%s  luci-i18n-mihowrt-ru.apk\n' "$ru" "$ru"
		} >"$out"
		;;
	*/luci-app-mihowrt.apk) printf 'app-bytes' >"$out" ;;
	*/luci-i18n-mihowrt-ru.apk)
		[ "$RU_MODE" = 404 ] && return 22
		printf 'ru-bytes' >"$out"
		;;
	*) return 22 ;;
	esac
}

fake_release ok
out="$(install_packages ru 2>&1)" || fail "install_packages must succeed: $out"
assert_eq "$BASE/SHA256SUMS
$BASE/luci-app-mihowrt.apk
$BASE/luci-i18n-mihowrt-ru.apk" "$(cat "$tmpdir/downloads")" "only fixed release URLs"
if grep -q 'api.github.com\|-r1.apk' "$tmpdir/downloads"; then fail "no API or -r1 URLs"; fi
pass "urls"

assert_file_contains "$apk_log" "apk add --allow-untrusted $WORK/luci-app-mihowrt.apk" "matching sums install the app"
[[ "$out" == *"Installing 0.10.0-r1..."* ]] || fail "version from SHA256SUMS: $out"
pass "version message"

fake_release bad
out="$( (install_packages en) 2>&1)" && fail "mismatch must abort"
[[ "$out" == *"sha256 mismatch for luci-app-mihowrt.apk"* ]] || fail "mismatch message: $out"
if grep -q 'allow-untrusted' "$apk_log"; then fail "no apk add after mismatch"; fi
fake_release missing
out="$( (install_packages en) 2>&1)" && fail "missing entry must abort"
[[ "$out" == *"no checksum for luci-app-mihowrt.apk"* ]] || fail "missing message: $out"
if grep -q 'allow-untrusted' "$apk_log"; then fail "no apk add without checksum"; fi
fake_release 404
out="$( (install_packages en) 2>&1)" && fail "404 must abort"
[[ "$out" == *"cannot download the release checksums"* ]] || fail "404 message: $out"
pass "checksum"

# Every chosen APK is verified before anything is installed.
for mode in bad missing; do
	fake_release ok "$mode"
	out="$( (install_packages ru) 2>&1)" && fail "ru $mode must abort"
	[[ "$out" == *"luci-i18n-mihowrt-ru.apk"* ]] || fail "ru $mode message: $out"
	if grep -q 'allow-untrusted' "$apk_log"; then fail "ru $mode: nothing may be installed"; fi
done
fake_release ok 404
out="$(install_packages ru 2>&1)" || fail "ru 404 stays a soft failure: $out"
[[ "$out" == *"Russian translation"* ]] || fail "ru 404 warning: $out"
assert_file_contains "$apk_log" "luci-app-mihowrt.apk" "app installed without ru"
if grep -q 'mihowrt-ru.apk' "$apk_log"; then fail "ru 404: no ru install"; fi
pass "all apks verified before install"

# Version comes from the line whose hash equals the app APK hash.
fake_release ok
curl_orig="$(declare -f curl)"
sums_other="$(printf 'other' | sha256sum | cut -d' ' -f1)"
app_h="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
curl() {
	local out="" prev="" a
	for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
	case "$a" in
	*/SHA256SUMS) printf '%s  luci-app-mihowrt-9.9.9-r9.apk\n%s *luci-app-mihowrt-0.10.0-r2.apk\n%s  luci-app-mihowrt.apk\n' "$sums_other" "$app_h" "$app_h" >"$out" ;;
	*/luci-app-mihowrt.apk) printf 'app-bytes' >"$out" ;;
	*) return 22 ;;
	esac
}
out="$(install_packages en 2>&1)" || fail "install must succeed: $out"
[[ "$out" == *"Installing 0.10.0-r2..."* ]] || fail "version by hash: $out"
eval "$curl_orig"
pass "version by hash"

# A failed core-update shows the backend error.
CORE="$tmpdir/absent-core"
MIHOWRT_BIN="$tmpdir/mihowrt-stub"
cat >"$MIHOWRT_BIN" <<'S'
#!/bin/sh
echo 'Error: Core update: not enough flash: need 62 MiB, free 40 MiB' >&2
echo '{"updated":false,"error":"not enough flash: need 62 MiB, free 40 MiB"}'
exit 1
S
chmod +x "$MIHOWRT_BIN"
install_packages() { :; }
resolve_language() { echo en; }
out="$( (MIHOWRT_ACTION=install do_install) 2>&1 >/dev/null)" && fail "core-update failure must abort"
[[ "$out" == *"not enough flash: need 62 MiB, free 40 MiB"* ]] || fail "core error shown: $out"
[[ "$out" == *"Mihomo core installation failed"* ]] || fail "failure message: $out"
printf '#!/bin/sh\necho "Error: boom" >&2\nexit 1\n' >"$MIHOWRT_BIN"
out="$( (MIHOWRT_ACTION=install do_install) 2>&1 >/dev/null)" && fail "no-JSON failure must abort"
[[ "$out" == *"Mihomo core installation failed"* ]] || fail "generic failure message: $out"
pass "core error shown"
