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
read -r -a seams <<<"$(sed -n 's/^unset \(.*\)\\$/\1/p' "$ROOT_DIR/tools/harden.sed")"
[[ ${#seams[@]} -gt 0 ]] || fail 'package hardening must unset environment seams'
for name in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY ALL_PROXY all_proxy no_proxy NO_PROXY CURL_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR CURL_HOME; do
 [[ " ${seams[*]} " == *" $name "* ]] || fail "package hardening must unset $name"
done
mapfile -t defaults < <(find "$ROOT_DIR/rootfs/usr" -type f \( -name '*.sh' -o -path "$ROOT_DIR/rootfs/usr/bin/*" \) \
 -exec grep -ohE '\$\{[a-zA-Z_][a-zA-Z0-9_]*:-' {} + | sed 's/^${//; s/:-$//' | sort -u)
[[ ${#defaults[@]} -gt 0 ]] || fail 'shell environment defaults must be discovered'
constants=" $(sed -n '/\${.*:-/d; s/^\([a-zA-Z_][a-zA-Z0-9_]*\)=.*/\1/p' "$MIHOWRT_LIB_DIR/constants.sh" | tr '\n' ' ')"
for name in "${defaults[@]}"; do
 [[ " ${seams[*]} $constants " == *" $name "* ]] && continue
 case "$name" in
 # settings_load owns these values; packaged SETTINGS_LOADED cannot bypass it.
 BLOCK_CLIENT_IPV6 | BYPASS_NTP | BYPASS_SUBSCRIPTION_DNS | DASHBOARD_ENABLED | DIRECT_LIST_SOURCE | DIRECT_LISTENER | \
 DISABLE_QUIC | DNS_HIJACK | DNS_MODE | DST_LIST_SOURCE | LISTS_INTERVAL | MIHOMO_LOG_LEVEL | NETBIRD_INTERFACE | NETBIRD_MARK | \
 NETBIRD_PROXY | POLICY_MODE | SOURCE_INTERFACES | SUBSCRIPTION_URL) ;;
 # http_fetch resets FETCH_HDR before subscription metadata is read.
 FETCH_HDR) ;;
 # route_state_read clears both before reading the saved route state.
 ROUTE_PRIORITY | ROUTE_TABLE) ;;
 # Function-local temporaries are initialized before use, not read from env.
 current | error | memlimit | restore_error | value) ;;
 # wait_for_ready reads the caller run_service's local stop=0 flag.
 stop) ;;
 *) fail "unreviewed environment default: $name" ;;
 esac
done
pass 'shell environment defaults are hardened, constants-owned or explicitly reviewed'
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
# The init script runs with the caller's environment under an rpcd write ACL: fix its PATH.
init_installed="$tmpdir/root/etc/init.d/mihowrt"
assert_file_not_contains "$init_installed" 'MIHOWRT_PACKAGE_HARDEN' 'installed init script has no hardening marker'
assert_eq 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$(sed -n '2p' "$init_installed")" 'init script fixes PATH right after the shebang'
assert_file_contains "$ROOT_DIR/rootfs/etc/init.d/mihowrt" '# MIHOWRT_PACKAGE_HARDEN_PATH' 'source init script keeps its marker'
sh -n "$init_installed"
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
assert_eq 'msgstr "Контрольная сумма не проверена"' "$(sed -n '/^msgid "checksum not verified"$/{n;p;}' "$po_file")" "checksum notice should start a new Russian sentence"

pass "i18n package Makefile and PO catalog"
