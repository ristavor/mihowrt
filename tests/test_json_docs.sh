#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
for name in README.md README.ru.md; do
 file="$ROOT_DIR/$name"
 assert_file_contains "$file" 'luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl' "$name runtime dependencies"
 assert_file_contains "$file" 'apk update && apk add luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl' "$name manual APK dependencies"
 assert_file_contains "$file" 'opkg update && opkg install luci-base cgi-io ucode ucode-mod-fs nftables kmod-nft-tproxy curl' "$name manual IPK dependencies"
 assert_file_not_contains "$file" 'cgi-io jq nftables' "$name must not install jq at runtime"
 pass "JSON docs: $name matches runtime dependencies"
done
assert_file_contains "$ROOT_DIR/docs/development.md" 'ucode-mod-fs' 'development docs name the helper module'
assert_file_not_contains "$ROOT_DIR/docs/development.md" 'ucode migration is not implemented' 'development docs reflect implemented helper'
pass 'JSON docs: development runtime description'
assert_file_not_contains "$ROOT_DIR/docs/open-issues.md" '**jq → ucode:**' 'completed migration is not a deferred issue'
pass 'JSON docs: completed migration removed from deferred issues'
assert_file_contains "$ROOT_DIR/tools/build-sdk.sh" 'Runtime dependencies (curl, ucode, ucode-mod-fs, nftables)' 'SDK help names current runtime dependencies'
pass 'JSON docs: SDK runtime dependency note'

assert_file_not_contains "$ROOT_DIR/README.ru.md" '256 МиБ не проверяли' 'README.ru does not claim 256 MiB was untested'
assert_file_contains "$ROOT_DIR/README.md" '## If internet is lost' 'README has recovery section'
assert_file_contains "$ROOT_DIR/README.ru.md" '## Если пропал интернет' 'README.ru has recovery section'
assert_file_contains "$ROOT_DIR/docs/user-guide.md" '## If internet is lost' 'user guide has recovery section'
assert_file_contains "$ROOT_DIR/docs/reference.md" '/usr/share/nftables.d/chain-pre/input/30-mihowrt.nft' 'reference notes guest fw4 include'
assert_file_contains "$ROOT_DIR/docs/reference.md" 'mihomo_log_level' 'reference notes log level option'
assert_file_contains "$ROOT_DIR/CHANGELOG.md" '30-mihowrt.nft' 'changelog notes guest fw4 include'
assert_file_contains "$ROOT_DIR/CHANGELOG.md" 'mihomo_log_level' 'changelog notes log level option'
assert_file_contains "$ROOT_DIR/CHANGELOG.md" 'subscription.json' 'changelog notes sysupgrade backup trim'
pass 'JSON docs: R16 and R50 documentation checks'

