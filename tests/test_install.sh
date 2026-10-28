#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

# A failed /dev/tty open must not terminate non-interactive BusyBox ash.
sed '/^main "\$@"$/d' "$ROOT_DIR/install.sh" >"$tmpdir/install-lib.sh"
cat >>"$tmpdir/install-lib.sh" <<'S'
can_prompt || echo no-terminal
echo after-prompt
S
out="$(setsid ash "$tmpdir/install-lib.sh" </dev/null 2>&1)" || fail "can_prompt aborted ash: $out"
assert_eq $'no-terminal\nafter-prompt' "$out" "ash survives absent controlling tty"
pass "can_prompt without tty"

set +u
source_install_lib
set -u
pkg_installed_orig="$(declare -f pkg_installed)"
can_prompt() { return 1; }

installed=""
pkg_installed() { [[ " $installed " == *" $1 "* ]]; }

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
free_kb() { echo 3072; }
# polish: no core space reserve
(
 set -e
 (check_space) >/dev/null 2>&1 || fail 'no core space reserve: 3 MiB must suffice without a core'
 assert_eq 0 "$(grep -c CORE_SPACE_KB "$ROOT_DIR/install.sh" || true)" 'no CORE_SPACE_KB reserve remains'
)
# Keep the removal no-regression fixture executable.
touch "$CORE"
chmod +x "$CORE"
pass 'no core space reserve'

calls="$tmpdir/calls"
mkdir -p "$tmpdir/bin"
printf '#!/bin/sh\necho "apk $*" >>"%s"\n' "$calls" >"$tmpdir/bin/apk"
chmod +x "$tmpdir/bin/apk"
PATH="$tmpdir/bin:$PATH"
FW4_BIN="$tmpdir/fw4"
touch "$FW4_BIN"
chmod +x "$FW4_BIN"
installed="luci-app-mihowrt luci-i18n-mihowrt-ru"
(MIHOWRT_ACTION=remove main) >/dev/null
assert_eq $'apk del luci-i18n-mihowrt-ru\napk del luci-app-mihowrt' "$(cat "$calls")" "translation removed before the app"
[[ -e "$CORE" ]] || fail "installer must leave core cleanup to prerm"
pass "remove"

installed=""
: >"$calls"
out="$(do_remove)"
[[ "$out" == *"MihoWRT is not installed."* ]] || fail "absent removal must report not installed: $out"
[[ ! -s "$calls" ]] || fail "absent removal must not delete packages"
pass "remove absent package"

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

# Dependency probes use the manager; update/add only when a dependency is absent.
(
 eval "$pkg_installed_orig"
 apk() {
  echo "apk $*" >>"$apk_log"
  if [ "$1" = info ]; then [[ " $present_deps " == *" $3 "* ]]; fi
 }
 present_deps="$DEPS"
 fake_release ok
 install_packages en >/dev/null
 if grep -qE '^apk (update|add [^-])' "$apk_log"; then fail "present dependencies must not be updated or added"; fi
 for dep in $DEPS; do
  assert_file_contains "$apk_log" "apk info -e $dep" "dependency checked: $dep"
 done
 present_deps="luci-base nftables kmod-nft-tproxy"
 fake_release ok
 install_packages en >/dev/null
 assert_eq 1 "$(grep -c '^apk update$' "$apk_log")" "update once for missing deps"
 assert_file_contains "$apk_log" "apk add cgi-io ucode ucode-mod-fs curl" "only missing deps installed"
)
pass "missing dependencies only"

# HTTPS assets cannot redirect to an insecure protocol; file mirrors still work.
(
 curl() { printf '%s\n' "$@" >"$tmpdir/curl.args"; }
 download_file SHA256SUMS "$tmpdir/sums"
 assert_file_contains "$tmpdir/curl.args" '--proto' "HTTPS protocol restricted"
 assert_file_contains "$tmpdir/curl.args" '--proto-redir' "HTTPS redirects restricted"
 assert_eq 2 "$(grep -c '^=https$' "$tmpdir/curl.args")" "HTTPS only for request and redirects"
 RELEASE_URL=http://mirror
 download_file SHA256SUMS "$tmpdir/sums" >"$tmpdir/http.out" 2>"$tmpdir/http.err"
 assert_file_contains "$tmpdir/http.err" 'Warning: MIHOWRT_RELEASE_URL uses plain HTTP' 'plain HTTP mirror warning on stderr'
 assert_eq '' "$(cat "$tmpdir/http.out")" 'HTTP warning never goes to stdout'
 RELEASE_URL=file:///mirror
 download_file SHA256SUMS "$tmpdir/sums" 2>"$tmpdir/file.err"
 assert_eq '' "$(cat "$tmpdir/file.err")" 'local mirror needs no warning'
 assert_file_not_contains "$tmpdir/curl.args" '--proto' "file mirror allowed"
)
assert_file_contains "$ROOT_DIR/README.md" 'mihowrt@v0.11.0/install.sh' "mirror pinned to release tag"
assert_file_contains "$ROOT_DIR/README.md" 'third-party' "mirror trust risk documented"
pass "release transport restrictions"

# The release base override covers checksums and both APKs.
fake_release ok
out="$(MIHOWRT_RELEASE_URL=file:///mirror source_install_lib; install_packages ru 2>&1)" || fail "mirror install failed: $out"
assert_eq $'file:///mirror/SHA256SUMS\nfile:///mirror/luci-app-mihowrt.apk\nfile:///mirror/luci-i18n-mihowrt-ru.apk' "$(cat "$tmpdir/downloads")" "release URL override covers all assets"
pass "release URL override"

# Restore the default release fixture for the version assertion below.
fake_release ok
out="$(install_packages ru 2>&1)" || fail "install_packages must succeed: $out"

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

# Exercise successful installs with only the init-script path relocated.
(
 sed -e '/^main "\$@"$/d' -e "s|/etc/init.d/mihowrt|$tmpdir/init-mihowrt|g" "$ROOT_DIR/install.sh" >"$tmpdir/install-success.sh"
 source "$tmpdir/install-success.sh"
 CORE="$tmpdir/existing-core"
 touch "$CORE"
 chmod +x "$CORE"
 printf '#!/bin/sh\necho "$*" >>"%s"\n' "$tmpdir/init.calls" >"$tmpdir/init-mihowrt"
 chmod +x "$tmpdir/init-mihowrt"
 resolve_language() { echo en; }
 pkg_installed() { [ "$1" = "$PKG" ] && [ "$fresh_case" = 0 ]; }
 pkg_version() { cat "$tmpdir/installed.version"; }
 install_packages() { echo "$next_version" >"$tmpdir/installed.version"; }
 for fresh_case in 1 0; do
  for old_version in 0.9.0-r1 0.10.0-r1; do
   next_version=0.10.0-r1
   echo "$old_version" >"$tmpdir/installed.version"
   : >"$tmpdir/init.calls"
   out="$(do_install)"
   if [ "$fresh_case" = 1 ]; then
    assert_eq enable "$(cat "$tmpdir/init.calls")" "fresh install enables service"
    [[ "$out" == *"MihoWRT is installed."* ]] || fail "fresh install message: $out"
   else
    [[ ! -s "$tmpdir/init.calls" ]] || fail "existing install must preserve autostart preference"
    if [ "$old_version" = "$next_version" ]; then
     [[ "$out" == *"MihoWRT is reinstalled (version unchanged)."* ]] || fail "same version message: $out"
    else
     [[ "$out" == *"MihoWRT is updated."* ]] || fail "changed version message: $out"
    fi
   fi
  done
 done
)
pass "install preserves autostart and reports version changes"

# opkg (OpenWrt 24.10): .ipk assets from the same SHA256SUMS, opkg commands,
# both file name formats in release_version.
mkdir -p "$tmpdir/obin"
printf '#!/bin/sh\necho "opkg $*" >>"%s"\n' "$tmpdir/opkg.log" >"$tmpdir/obin/opkg"
chmod +x "$tmpdir/obin/opkg"
# The test image is Alpine and ships apk: an opkg-only PATH carries just the tools used.
for tool in awk grep cat rm mkdir sha256sum cut sed tr wc head df; do
 ln -s "$(command -v "$tool")" "$tmpdir/obin/$tool"
done
(
 set +u
 source_install_lib
 set -u
 check_space() { :; }
 # shellcheck disable=SC2030,SC2031
 export PATH="$tmpdir/obin"
 opkg_log="$tmpdir/opkg.log"
 select_manager
 assert_eq opkg "$MANAGER" "opkg selected without apk"
 assert_eq ipk "$EXT" "opkg uses ipk assets"
 curl() {
  local out="" prev="" a url=""
  for a in "$@"; do
   [ "$prev" = "-o" ] && out="$a"
   prev="$a"
   url="$a"
  done
  echo "$url" >>"$tmpdir/downloads"
  app="$(printf 'app-ipk' | sha256sum | cut -d' ' -f1)"
  ru="$(printf 'ru-ipk' | sha256sum | cut -d' ' -f1)"
  case "$url" in
  */SHA256SUMS) printf '%s  luci-app-mihowrt_0.11.0-r2_all.ipk\n%s  luci-app-mihowrt.ipk\n%s  luci-i18n-mihowrt-ru_0.11.0-r2_all.ipk\n%s  luci-i18n-mihowrt-ru.ipk\n' "$app" "$app" "$ru" "$ru" >"$out" ;;
  */luci-app-mihowrt.ipk) printf 'app-ipk' >"$out" ;;
  */luci-i18n-mihowrt-ru.ipk) printf 'ru-ipk' >"$out" ;;
  *) return 22 ;;
  esac
 }
 new_work() { rm -f "$tmpdir/downloads" "$opkg_log"; WORK="$tmpdir/owork.$RANDOM"; mkdir -p "$WORK"; }

 # All dependencies present: no update, no feed install.
 pkg_installed_names() { printf '%s\n' luci-base cgi-io nftables-json ucode ucode-mod-fs kmod-nft-tproxy curl; }
 new_work
 out="$(install_packages ru 2>&1)" || fail "opkg install must succeed: $out"
 [[ "$out" == *"Installing 0.11.0-r2..."* ]] || fail "ipk version from SHA256SUMS: $out"
 assert_eq "opkg install $WORK/luci-app-mihowrt.ipk
opkg install $WORK/luci-i18n-mihowrt-ru.ipk" "$(cat "$opkg_log")" "present dependencies: only the two ipk files install"
 assert_eq "$BASE/SHA256SUMS
$BASE/luci-app-mihowrt.ipk
$BASE/luci-i18n-mihowrt-ru.ipk" "$(cat "$tmpdir/downloads")" "ipk assets from the same release"

 # nftables-nojson also satisfies nftables; missing deps are updated and installed once.
 pkg_installed_names() { printf '%s\n' luci-base nftables-nojson kmod-nft-tproxy; }
 new_work
 install_packages en >/dev/null 2>&1 || fail "opkg install with missing deps must succeed"
 assert_eq "opkg update
opkg install cgi-io ucode ucode-mod-fs curl
opkg install $WORK/luci-app-mihowrt.ipk" "$(cat "$opkg_log")" "only missing deps installed through opkg"
 pkg_installed_names() { printf '%s\n' luci-base cgi-io kmod-nft-tproxy ucode ucode-mod-fs curl; }
 new_work
 install_packages en >/dev/null 2>&1 || fail "opkg install without nftables must succeed"
 assert_file_contains "$opkg_log" "opkg install nftables" "nftables installed when no variant is present"

 # Switching to English removes the Russian package with opkg.
 pkg_installed_names() { printf '%s\n' luci-base cgi-io nftables-json ucode ucode-mod-fs kmod-nft-tproxy curl luci-i18n-mihowrt-ru; }
 new_work
 install_packages en >/dev/null 2>&1 || fail "opkg english reinstall must succeed"
 assert_file_contains "$opkg_log" "opkg remove luci-i18n-mihowrt-ru" "Russian package removed for English"

 # Version by hash also reads the apk name format when the manager is apk.
 EXT=apk
 curl() {
  local out="" prev="" a url=""
  for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; url="$a"; done
  app="$(printf 'app-bytes' | sha256sum | cut -d' ' -f1)"
  case "$url" in
  */SHA256SUMS) printf '%s  luci-app-mihowrt-0.12.0-r3.apk\n%s  luci-app-mihowrt.apk\n' "$app" "$app" >"$out" ;;
  esac
 }
 new_work
 curl -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS"
 assert_eq 0.12.0-r3 "$(release_version)" "apk name format"
 EXT=ipk
 printf '%s  luci-app-mihowrt_0.12.0-r3_all.ipk\n%s  luci-app-mihowrt.ipk\n' "$app" "$app" >"$WORK/SHA256SUMS"
 assert_eq 0.12.0-r3 "$(release_version)" "ipk name format"
 printf '%s  luci-app-mihowrt-0.12.0-r3.apk\n%s  luci-app-mihowrt.ipk\n' "$app" "$app" >"$WORK/SHA256SUMS"
 assert_eq "" "$(release_version)" "an apk line is not an ipk version"
)
pass "opkg install"

# opkg remove removes the translation before the app.
(
 set +u
 source_install_lib
 set -u
 # shellcheck disable=SC2030,SC2031
 export PATH="$tmpdir/obin"
 select_manager
 : >"$tmpdir/opkg.log"
 pkg_installed_names() { printf '%s\n' luci-app-mihowrt luci-i18n-mihowrt-ru; }
 (do_remove) >/dev/null
 assert_eq "opkg remove luci-i18n-mihowrt-ru
opkg remove luci-app-mihowrt" "$(cat "$tmpdir/opkg.log")" "opkg removes translation, then app"
 : >"$tmpdir/opkg.log"
 pkg_installed_names() { :; }
 out="$(do_remove)"
 [[ "$out" == *"MihoWRT is not installed."* ]] || fail "opkg absent removal: $out"
 [[ ! -s "$tmpdir/opkg.log" ]] || fail "opkg absent removal must not call opkg"
)
pass "opkg remove"

# Platform gate: fw4 everywhere; opkg needs OpenWrt 24.10 or newer.
(
 FW4_BIN="$tmpdir/no-such-fw4"
 MANAGER=apk
 out="$( (check_platform) 2>&1)" && fail "missing fw4 must abort"
 [[ "$out" == *"firewall4"* ]] || fail "fw4 message: $out"
 FW4_BIN="$tmpdir/fw4"
 check_platform || fail "apk with fw4 must pass without a release file"
 MANAGER=opkg
 OPENWRT_RELEASE_FILE="$tmpdir/openwrt_release"
 gate() { printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='%s'\n" "$1" >"$OPENWRT_RELEASE_FILE"; (check_platform) 2>&1; }
 for ok_release in 24.10.0 24.10.8 24.10.0-rc1 24.10-SNAPSHOT 25.12.6 25.12.0-rc2 100.1.0; do
  gate "$ok_release" >/dev/null || fail "release $ok_release must be accepted"
 done
 for old_release in 23.05.5 24.9.9 24.09.1 22.03.7 21.02.0; do
  out="$(gate "$old_release")" && fail "release $old_release must be refused"
  [[ "$out" == *"needs 24.10 or newer"* ]] || fail "old release message for $old_release: $out"
 done
 for odd_release in SNAPSHOT '' 24 24. .10 x.y; do
  out="$(gate "$odd_release")" && fail "release '$odd_release' must be refused"
  [[ "$out" == *"unrecognized OpenWrt release"* ]] || fail "odd release message for '$odd_release': $out"
 done
 rm -f "$OPENWRT_RELEASE_FILE"
 out="$( (check_platform) 2>&1)" && fail "missing release file must abort on opkg"
 [[ "$out" == *"unrecognized OpenWrt release 'unknown'"* ]] || fail "missing release file message: $out"
 FW4_BIN="$tmpdir/no-such-fw4"
 out="$( (check_platform) 2>&1)" && fail "opkg without fw4 must abort"
 [[ "$out" == *"firewall4"* ]] || fail "opkg fw4 message: $out"
)
pass "platform gate"

# No package manager at all: clear message, nothing touched.
(
 pkg_manager() { return 1; }
 out="$( (select_manager) 2>&1)" && fail "no manager must abort"
 [[ "$out" == *"no supported package manager (apk or opkg)"* ]] || fail "no manager message: $out"
)
pass "no package manager"
