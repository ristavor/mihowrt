#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

# Check Makefile package version
assert_file_contains "$ROOT_DIR/Makefile" "PKG_VERSION:=0.9.0" "Makefile PKG_VERSION should be 0.9.0"

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
