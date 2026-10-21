#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
load_modules constants.sh helpers.sh

expected="validate.sh settings.sh mihomo-config.sh mihomo-api.sh fetch.sh subscription.sh lists.sh dns.sh nft.sh route.sh config.sh core.sh service.sh status.sh migration.sh"
assert_eq "$expected" "$MIHOWRT_MODULES" "runtime module order"
assert_false "kernel.sh removed" test -e "$MIHOWRT_LIB_DIR/kernel.sh"
assert_false "KERNEL_ constants removed" grep -rn KERNEL_ "$ROOT_DIR/rootfs"
for module in $MIHOWRT_MODULES; do
 assert_true "$module exists" test -f "$MIHOWRT_LIB_DIR/$module"
done
for name in CORE_TMP_DIR CORE_RELEASE_JSON_MAX_BYTES CORE_ASSET_MAX_BYTES; do
 assert_true "$name defined" test -n "${!name}"
done
assert_true "awk generator installed by package wildcard" grep -qF '$(CP) ./rootfs/usr/lib/mihowrt/* $(1)/usr/lib/mihowrt/' "$ROOT_DIR/Makefile"
assert_true "awk generator exists" test -f "$MIHOWRT_LIB_DIR/mihomo-config.awk"
for module in core.sh subscription.sh lists.sh; do
 (
  load_modules "$module"
  case "$module" in
  core.sh) declare -F core_update >/dev/null ;;
  subscription.sh) declare -F subscription_update userinfo_field subscription_due >/dev/null ;;
  lists.sh) declare -F lists_install lists_apply lists_refresh >/dev/null ;;
  esac
 ) || fail "$module owns its interfaces"
done
pass "runtime modules and packaged generator"
