#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"

# Package-manager adapter under BusyBox ash with apk and opkg stubs, plus
# byte parity between rootfs pkg.sh and the copy embedded in install.sh.

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/apk-bin" "$tmpdir/opkg-bin" "$tmpdir/none-bin"

for tool in ash awk grep cat echo; do
	for dir in apk-bin opkg-bin none-bin; do
		ln -s "$(command -v busybox)" "$tmpdir/$dir/$tool" 2>/dev/null || true
	done
done
cat >"$tmpdir/apk-bin/apk" <<'S'
#!/bin/ash
echo "apk $*" >>"$PKG_CALLS"
case "$*" in
'info -e present') exit 0 ;;
'info -e '*) exit 1 ;;
'info -v luci-app-mihowrt') echo luci-app-mihowrt-0.10.0-r1 ;;
'info -v '*) exit 1 ;;
esac
S
cat >"$tmpdir/opkg-bin/opkg" <<'S'
#!/bin/ash
echo "opkg $*" >>"$PKG_CALLS"
S
chmod +x "$tmpdir/apk-bin/apk" "$tmpdir/opkg-bin/opkg"

# Relocate the databases and run the real functions in BusyBox ash.
sed "s|/lib/apk/db/installed|$tmpdir/apk-installed|g; s|/usr/lib/opkg/status|$tmpdir/opkg-status|g" \
	"$MIHOWRT_LIB_DIR/pkg.sh" >"$tmpdir/pkg.sh"
printf 'Package: luci-app-mihowrt\nVersion: 0.11.0-r1\nDepends: libc\nStatus: install ok installed\n\nPackage: nftables-json\nVersion: 1.1.1-r1\nStatus: install ok installed\n\nPackage: jq\nVersion: 1.8.1-r1\nStatus: deinstall ok not-installed\n\nPackage: curl\nVersion: 8.0-r1\nStatus: install ok user\n' >"$tmpdir/opkg-status"

# pkg_run <bin dir> <command...>: BusyBox ash with only that manager on PATH.
export PKG_CALLS="$tmpdir/calls"
pkg_run() {
	local dir="$1"
	shift
	PATH="$tmpdir/$dir" ash -c ". '$tmpdir/pkg.sh'; \"\$@\"" pkg "$@"
}

assert_eq apk "$(pkg_run apk-bin pkg_manager)" "apk detected"
assert_eq opkg "$(pkg_run opkg-bin pkg_manager)" "opkg detected"
if pkg_run none-bin pkg_manager >/dev/null 2>&1; then fail "no manager must fail"; fi
mkdir -p "$tmpdir/both-bin"
cp -P "$tmpdir"/apk-bin/* "$tmpdir"/opkg-bin/opkg "$tmpdir/both-bin/"
assert_eq apk "$(pkg_run both-bin pkg_manager)" "apk wins when both exist"
pass "pkg_manager"

: >"$PKG_CALLS"
pkg_run apk-bin pkg_installed present || fail "apk present"
if pkg_run apk-bin pkg_installed absent; then fail "apk absent"; fi
assert_eq $'apk info -e present\napk info -e absent' "$(cat "$PKG_CALLS")" "apk asks apk info -e"
pkg_run opkg-bin pkg_installed nftables-json || fail "opkg installed name"
if pkg_run opkg-bin pkg_installed jq; then fail "opkg not-installed record must not count"; fi
if pkg_run opkg-bin pkg_installed nftables; then fail "opkg lists real names only"; fi
pkg_run opkg-bin pkg_installed curl >/dev/null 2>&1 && fail "opkg user-flag record is not 'installed'"
pkg_run opkg-bin pkg_installed luci-app-mihowrt || fail "opkg app installed"
pass "pkg_installed"

assert_eq 0.10.0-r1 "$(pkg_run apk-bin pkg_version luci-app-mihowrt)" "apk version"
assert_eq "" "$(pkg_run apk-bin pkg_version absent)" "apk absent version"
assert_eq 0.11.0-r1 "$(pkg_run opkg-bin pkg_version luci-app-mihowrt)" "opkg version"
assert_eq "" "$(pkg_run opkg-bin pkg_version jq)" "opkg not-installed version"
pass "pkg_version"

: >"$PKG_CALLS"
pkg_run apk-bin pkg_install_file /tmp/a.apk
pkg_run apk-bin pkg_install jq curl
pkg_run apk-bin pkg_remove i18n app
pkg_run apk-bin pkg_update
pkg_run opkg-bin pkg_install_file /tmp/a.ipk
pkg_run opkg-bin pkg_install jq curl
pkg_run opkg-bin pkg_remove i18n app
pkg_run opkg-bin pkg_update
assert_eq "apk add --allow-untrusted /tmp/a.apk
apk add jq curl
apk del i18n app
apk update
opkg install /tmp/a.ipk
opkg install jq curl
opkg remove i18n app
opkg update" "$(cat "$PKG_CALLS")" "manager command lines"
if pkg_run none-bin pkg_update 2>/dev/null; then fail "update without manager must fail"; fi
pass "pkg_install_file pkg_install pkg_remove pkg_update"

# pkg_installed_names: apk database wins; opkg lists only installed records.
printf 'P:foo\nV:1\n\nP:bar\n' >"$tmpdir/apk-installed"
assert_eq $'foo\nbar' "$(pkg_run apk-bin pkg_installed_names)" "apk names"
rm "$tmpdir/apk-installed"
assert_eq $'luci-app-mihowrt\nnftables-json' "$(pkg_run opkg-bin pkg_installed_names)" "opkg installed names"
pass "pkg_installed_names"

# Parity: install.sh embeds each adapter function byte for byte.
extract_function() { # extract_function <file> <name>
	awk -v n="$2" '$0 == n "() {" { f = 1 } f { print } f && $0 == "}" { exit }' "$1"
}
for name in pkg_manager pkg_installed_names pkg_installed pkg_version pkg_install_file pkg_install pkg_remove pkg_update; do
	module_copy="$(extract_function "$MIHOWRT_LIB_DIR/pkg.sh" "$name")"
	[[ -n "$module_copy" ]] || fail "pkg.sh lacks $name"
	assert_eq "$module_copy" "$(extract_function "$ROOT_DIR/install.sh" "$name")" "install.sh copy of $name equals pkg.sh"
done
pass "installer adapter parity"
