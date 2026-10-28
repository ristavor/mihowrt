#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

# Exercise the actual package install define, including its version rewrite.
assert_file_contains "$MIHOWRT_LIB_DIR/constants.sh" 'PKG_VERSION="dev"' "repository version should be dev"
package_makefile >"$tmpdir/package.mk"
cat >>"$tmpdir/package.mk" <<'EOF'
INSTALL_DIR=mkdir -p
INSTALL_BIN=cp
INSTALL_CONF=cp
INSTALL_DATA=cp
CP=cp -R
.PHONY: install-test
define InstallTest
install-test:
$(call Package/$(PKG_NAME)/install,$(DESTDIR))
endef
$(eval $(InstallTest))
EOF
(cd "$ROOT_DIR" && make -s -f "$tmpdir/package.mk" install-test PKG_VERSION=9.9.9 DESTDIR="$tmpdir/root" CONFIG_USE_APK=y)
assert_file_contains "$tmpdir/root/usr/lib/mihowrt/constants.sh" 'PKG_VERSION="9.9.9"' "installed version should come from Makefile"
# Exercise the installed bootstrap before any module load or command dispatch.
seams=(MIHOWRT_BACKEND MIHOWRT_LIB_DIR SUBSCRIPTION_META_FILE JOB_PROC_DIR ROUTE_PROC_ROOT RC_D_DIR
 LOCK_DEPTH SETTINGS_LOADED SETTINGS_UCI_SNAPSHOT NET_REFRESH_DELAY DASHBOARD_WAIT_SECONDS
 RUNTIME_LOCK_TIMEOUT API_DELAY_URL SUBSCRIPTION_MAX_BYTES SUBSCRIPTION_TIMEOUT
 LISTS_REMOTE_MAX_BYTES LISTS_REMOTE_MAX_URLS LISTS_REMOTE_TIMEOUT MIHOWRT_QUIET MIHOWRT_STOP)
poison=()
for seam in "${seams[@]}"; do poison+=("$seam=/tmp/hostile"); done
for entry in mihowrt mihowrt-read; do
 installed="$tmpdir/root/usr/bin/$entry"
 assert_file_not_contains "$installed" 'MIHOWRT_PACKAGE_HARDEN' "installed $entry has no hardening marker"
 assert_eq unset "$(sed -n '2s/ .*//p' "$installed")" "$entry clears seams immediately after shebang"
 sh -n "$installed"
 sed -e '/^\. "\$LIB\/constants.sh"/,$d' -e '/^case /,$d' "$installed" >"$tmpdir/bootstrap"
 printf '\n/usr/bin/env\n' >>"$tmpdir/bootstrap"
 env "${poison[@]}" PATH=/tmp/hostile /bin/ash "$tmpdir/bootstrap" >"$tmpdir/environment"
 for seam in "${seams[@]}"; do
  assert_false "$entry ignores inherited $seam" grep -q "^$seam=" "$tmpdir/environment"
 done
 assert_true "$entry sets a trusted PATH" grep -qxF 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$tmpdir/environment"
done
assert_file_contains "$tmpdir/root/usr/bin/mihowrt" 'LIB=/usr/lib/mihowrt' 'installed CLI fixes library path'
assert_file_contains "$tmpdir/root/usr/bin/mihowrt-read" 'BACKEND=/usr/bin/mihowrt' 'installed read wrapper fixes backend'
assert_eq /usr/lib/mihowrt "$(MIHOWRT_LIB_DIR=/tmp/hostile ash -c '. "$1"; mihowrt_lib_dir' sh "$tmpdir/root/usr/lib/mihowrt/helpers.sh")" 'installed helpers ignore library override'
sh -n "$tmpdir/root/usr/lib/mihowrt/helpers.sh"
assert_file_contains "$ROOT_DIR/rootfs/usr/bin/mihowrt" 'LIB="${MIHOWRT_LIB_DIR:-/usr/lib/mihowrt}"' 'source CLI retains test seam'
assert_file_contains "$ROOT_DIR/rootfs/usr/bin/mihowrt-read" 'BACKEND="${MIHOWRT_BACKEND:-/usr/bin/mihowrt}"' 'source read wrapper retains test seam'
pass 'packaged entrypoints ignore hostile seam environment and retain ash syntax'

luci_depends="$(sed -n 's/^LUCI_DEPENDS:=//p' "$ROOT_DIR/Makefile")"
[[ " $luci_depends " == *" +cgi-io "* ]] || fail "LUCI_DEPENDS should explicitly contain +cgi-io"
for list in always_proxy_dst always_proxy_src direct_dst direct_src; do
	[[ -f "$tmpdir/root/opt/clash/lst/$list.txt" ]] || fail "install should include $list"
done
pass "version from Makefile and cgi-io dependency"

for script in "$ROOT_DIR/rootfs/etc/init.d/mihowrt" "$ROOT_DIR/rootfs/etc/hotplug.d/iface/90-mihowrt"; do
	assert_file_contains "$script" '. /usr/lib/mihowrt/constants.sh' "service entrypoints should source constants"
	assert_file_not_contains "$script" '/var/run/mihowrt/stopped' "Stop path should come from constants"
	assert_file_not_contains "$script" 'mihowrt run-service' "supervisor command should come from constants"
done
assert_file_contains "$MIHOWRT_LIB_DIR/constants.sh" 'SUPERVISOR_CMD="/usr/bin/mihowrt run-service"' "supervisor command has one definition"
pass "constants sourced"

# Check Makefile package definitions
assert_file_contains "$ROOT_DIR/Makefile" "define Package/luci-i18n-mihowrt-ru" "Makefile should define Package/luci-i18n-mihowrt-ru"
assert_file_contains "$ROOT_DIR/Makefile" '$(eval $(call BuildPackage,luci-i18n-mihowrt-ru))' "Makefile should call BuildPackage for luci-i18n-mihowrt-ru"
assert_file_contains "$ROOT_DIR/Makefile" "po2lmo" "Makefile should invoke po2lmo for PO compilation"
assert_file_contains "$ROOT_DIR/Makefile" "/usr/lib/lua/luci/i18n" "Makefile should install to /usr/lib/lua/luci/i18n"
assert_file_contains "$ROOT_DIR/Makefile" "mihowrt.ru.lmo" "Makefile should produce mihowrt.ru.lmo"

# Check language registration in standard LuCI
assert_file_contains "$ROOT_DIR/Makefile" "luci.languages.ru" "Makefile should register ru in standard luci.languages"

# Check PO file existence and structure
po_file="$ROOT_DIR/po/ru/mihowrt.po"
[[ -f "$po_file" ]] || fail "po/ru/mihowrt.po file missing"

assert_file_contains "$po_file" 'msgid "MihoWRT"' "PO file should contain MihoWRT msgid"
assert_file_contains "$po_file" 'msgid "Overview"' "PO file should contain Overview msgid"
assert_file_contains "$po_file" 'msgid "Subscription"' "PO file should contain Subscription msgid"
assert_file_contains "$po_file" 'msgid "Traffic"' "PO file should contain Traffic msgid"
assert_file_contains "$po_file" 'msgid "Diagnostics"' "PO file should contain Diagnostics msgid"
assert_file_contains "$po_file" 'msgid "All traffic via proxy except exclusions"' "PO file should contain policy mode translation"

pass "i18n package Makefile and PO catalog"
