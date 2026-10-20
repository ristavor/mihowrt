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

cat >"$tmpdir/release.json" <<'J'
{"tag_name":"v0.8.0","assets":[
 {"name":"luci-i18n-mihowrt-ru-0.8.0-r1.apk","browser_download_url":"https://x/ru.apk","digest":"sha256:aa"},
 {"name":"luci-app-mihowrt-0.8.0-r1.apk","browser_download_url":"https://x/app.apk","digest":"sha256:bb"}]}
J
assert_eq "https://x/app.apk sha256:bb" "$(asset_info "$tmpdir/release.json" luci-app-mihowrt)" "app asset, not translation"
assert_eq "https://x/ru.apk sha256:aa" "$(asset_info "$tmpdir/release.json" luci-i18n-mihowrt-ru)" "translation asset"
pass "asset selection"

calls="$tmpdir/calls"
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$calls" >"$tmpdir/bin/apk"
chmod +x "$tmpdir/bin/apk"
PATH="$tmpdir/bin:$PATH"
installed="luci-app-mihowrt luci-i18n-mihowrt-ru"
do_remove >/dev/null
assert_eq $'apk del luci-i18n-mihowrt-ru\napk del luci-app-mihowrt' "$(cat "$calls")" "translation removed before the app"
[[ ! -e "$CORE" ]] || fail "core removed"
pass "remove"
