#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh mihomo-config.sh core.sh service.sh
setup_runtime_paths "$tmpdir"
CONFIG_TESTED_FILE="$PKG_STATE_DIR/config.tested"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.yaml"
CLASH_BIN="$tmpdir/core"
export TEST_CORE_DIR="$tmpdir"
cat >"$CLASH_BIN" <<'CORE'
#!/bin/sh
if [ "$1" = -v ]; then cat "$TEST_CORE_DIR/version"; exit 0; fi
echo test >>"$TEST_CORE_DIR/calls"
[ ! -f "$TEST_CORE_DIR/reject" ] || { echo 'invalid config' >&2; exit 1; }
CORE
chmod +x "$CLASH_BIN"
printf 'Mihomo v1.2.3\n' >"$tmpdir/version"
printf 'mode: rule\n' >"$CLASH_CONFIG"
mihomo_config_generate() { cp "$1" "$2"; printf 'profile\n' >"$2.profile"; }
mihomo_memory_limit() { echo 128MiB; }
settings_load() { :; }
cron_update() { :; }
service_ready() { return 0; }
policy_apply() { :; }
api_reload() { :; }
assert_stamp() {
 local hash
 hash="$(sha256sum "$1" | cut -d' ' -f1)"
 assert_true 'successful config test writes stamp' test -f "$CONFIG_TESTED_FILE"
 assert_eq "$hash $2" "$(cat "$CONFIG_TESTED_FILE")" 'stamp identifies config bytes and tested core'
}
run_case() (
 case "$1" in
 miss)
  sha256sum() { echo hash >>"$tmpdir/hashes"; command sha256sum "$@"; }
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/hashes" | tr -d ' ')" 'start stamp miss hashes runtime config only once'
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'start stamp miss tests core'
  assert_stamp "$RUNTIME_CONFIG" v1.2.3
  ;;
 hit)
  runtime_config_build "$RUNTIME_CONFIG"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'start stamp hit skips duplicate core test'
  assert_stamp "$RUNTIME_CONFIG" v1.2.3
  ;;
 config)
  runtime_config_build "$RUNTIME_CONFIG"
  printf 'mode: global\n' >"$CLASH_CONFIG"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 2 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'config change retests core'
  assert_stamp "$RUNTIME_CONFIG" v1.2.3
  ;;
 core)
  runtime_config_build "$RUNTIME_CONFIG"
  printf 'Mihomo v1.2.4\n' >"$tmpdir/version"
  rm -f "$CORE_VERSION_CACHE"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 2 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'core version change retests config'
  assert_stamp "$RUNTIME_CONFIG" v1.2.4
  ;;
 candidate)
  mihomo_config_test "$CLASH_CONFIG" "$CLASH_BIN"
  assert_stamp "$CLASH_CONFIG" v1.2.3
  runtime_config_build "$RUNTIME_CONFIG"
  assert_eq 1 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'successful explicit-binary test seeds start stamp'
  ;;
 failed)
  touch "$tmpdir/reject"
  assert_false 'rejected config fails' mihomo_config_test "$CLASH_CONFIG" 2>/dev/null
  assert_false 'failed first test does not stamp' test -e "$CONFIG_TESTED_FILE"
  rm "$tmpdir/reject"
  runtime_config_build "$RUNTIME_CONFIG"
  assert_stamp "$RUNTIME_CONFIG" v1.2.3
  cp "$CONFIG_TESTED_FILE" "$tmpdir/stamp.before"
  touch "$tmpdir/reject"
  printf 'mode: global\n' >"$CLASH_CONFIG"
  assert_false 'changed rejected config fails start' runtime_config_build "$RUNTIME_CONFIG" 2>/dev/null
  assert_true 'failed test preserves previous stamp' cmp -s "$tmpdir/stamp.before" "$CONFIG_TESTED_FILE"
  ;;
 reload)
  runtime_config_build "$RUNTIME_CONFIG"
  printf 'mode: global\n' >"$CLASH_CONFIG"
  mihomo_config_test "$CLASH_CONFIG"
  assert_stamp "$CLASH_CONFIG" v1.2.3
  service_reload
  assert_eq 3 "$(wc -l <"$tmpdir/calls" | tr -d ' ')" 'changed reload tests even with matching stamp'
  ;;
 esac
)
cases=(miss hit config core candidate failed reload)
[ $# -eq 0 ] || cases=("$@")
for scenario in "${cases[@]}"; do
 rm -f "$tmpdir/calls" "$tmpdir/hashes" "$tmpdir/reject" "$CONFIG_TESTED_FILE" "$CORE_VERSION_CACHE"
 printf 'Mihomo v1.2.3\n' >"$tmpdir/version"
 printf 'mode: rule\n' >"$CLASH_CONFIG"
 run_case "$scenario"
 pass "config test stamp: $scenario"
done
