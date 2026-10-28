#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
# Runtime JSON must work without jq; jq remains an independent test oracle.
modules=(settings status job lists subscription config core mihomo-api)
for module in "${modules[@]}"; do
 assert_file_not_contains "$MIHOWRT_LIB_DIR/$module.sh" 'jq ' "$module still invokes jq"
 pass "JSON runtime: $module has no jq call"
done
for file in "$ROOT_DIR/rootfs/usr/bin/mihowrt" "$ROOT_DIR/install.sh"; do
 assert_file_not_contains "$file" 'jq -' "$file still invokes jq"
 pass "JSON runtime: ${file##*/} has no jq call"
done
assert_file_not_contains "$ROOT_DIR/Makefile" '+jq' 'package still depends on jq'
assert_file_contains "$ROOT_DIR/Makefile" '+ucode ' 'package requires ucode'
assert_file_contains "$ROOT_DIR/Makefile" '+ucode-mod-fs' 'package requires the fs module'
assert_file_not_contains "$ROOT_DIR/install.sh" 'nftables jq ' 'installer still depends on jq'
pass 'JSON runtime: ucode and fs replace the jq dependency'
assert_file_contains "$ROOT_DIR/Makefile" '$(INSTALL_BIN) ./rootfs/usr/bin/mihowrt-json $(1)/usr/bin/' 'package must install the helper executable'
pass 'JSON runtime: helper executable is packaged'
