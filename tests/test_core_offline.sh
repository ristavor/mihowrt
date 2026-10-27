#!/usr/bin/env bash

set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh lists.sh fetch.sh subscription.sh core.sh service.sh
setup_runtime_paths "$tmpdir"
CORE_TMP_DIR="$PKG_TMP_DIR/kernel"
CLASH_DIR="$tmpdir/clash"
CLASH_BIN="$CLASH_DIR/bin/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
mkdir -p "$CLASH_DIR/bin"
echo 'mode: rule' >"$CLASH_CONFIG"
http_fetch() { fail 'offline install must not fetch'; }
core_arch() { fail 'offline install must not need architecture detection'; }
core_free_kb() { echo 1000000; }
warn() { printf '%s\n' "$*" >>"$tmpdir/warnings"; }
export OFFLINE_TEST_LOG="$tmpdir/test.log"
cat >"$tmpdir/local core" <<'CORE'
#!/bin/sh
case "$1" in
-v) echo 'Mihomo v1.2.3' ;;
-t|-d)
 echo tested >>"$OFFLINE_TEST_LOG"
 [ "${OFFLINE_REJECT:-0}" != 1 ]
 ;;
esac
CORE
gzip -c "$tmpdir/local core" >"$tmpdir/local core.gz"
for file in "$tmpdir/local core.gz" "$tmpdir/local core"; do
 printf '#!/bin/sh\necho "Mihomo v1.0.0"\n' >"$CLASH_BIN"
 chmod +x "$CLASH_BIN"
 rm -f "$CORE_VERSION_CACHE" "$OFFLINE_TEST_LOG"
 : >"$tmpdir/warnings"
 core_update "$file" || fail "offline install: $CORE_ERROR"
 assert_eq '1:v1.2.3' "$CORE_UPDATED:$CORE_VERSION" 'offline version and updated state'
 assert_true 'offline binary installed byte-identically' cmp -s "$tmpdir/local core" "$CLASH_BIN"
 assert_eq tested "$(cat "$OFFLINE_TEST_LOG")" 'offline candidate config tested'
 assert_file_contains "$tmpdir/warnings" 'skipping release digest check' 'offline digest bypass logged'
 assert_true 'offline source retained' test -f "$file"
 assert_false 'offline success removes YAML' test -e "$PKG_TMP_DIR/core-test.yaml"
 assert_false 'offline success removes profile' test -e "$PKG_TMP_DIR/core-test.yaml.profile"
 pass "offline core install: ${file##*/}"
done
printf garbage >"$tmpdir/bad"
printf garbage >"$tmpdir/bad.gz"
cp "$CLASH_BIN" "$tmpdir/before"
for file in "$tmpdir/missing" "$tmpdir" "$tmpdir/bad" "$tmpdir/bad.gz"; do
 if core_update "$file" 2>/dev/null; then fail "invalid local core accepted: $file"; fi
 case "$CORE_ERROR" in
 'cannot read local core file'|'new binary does not run on this router'|'unpack failed') ;;
 *) fail "unclear local file error: $CORE_ERROR" ;;
 esac
 assert_eq 0 "$CORE_UPDATED" 'invalid file not marked updated'
 assert_true 'invalid file keeps old core' cmp -s "$CLASH_BIN" "$tmpdir/before"
 assert_false 'invalid file removes candidate' test -e "$CLASH_BIN.new"
 pass "offline invalid file rejected: ${file##*/}"
done
if OFFLINE_REJECT=1 core_update "$tmpdir/local core.gz" 2>/dev/null; then fail 'offline config rejection must fail'; fi
assert_eq 'new core rejects the current config' "$CORE_ERROR" 'offline config error'
assert_true 'offline config rejection keeps old core' cmp -s "$CLASH_BIN" "$tmpdir/before"
assert_false 'offline failure removes YAML' test -e "$PKG_TMP_DIR/core-test.yaml"
assert_false 'offline failure removes profile' test -e "$PKG_TMP_DIR/core-test.yaml.profile"
pass 'offline config rejection keeps old core'
# JSON layer forwards the optional local path too.
result="$(core_update_json "$tmpdir/local core")"
assert_eq '{"updated":true,"version":"v1.2.3","error":null}' "$result" 'offline JSON result'
pass 'offline JSON forwards local file'
