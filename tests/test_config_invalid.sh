#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/testlib.sh"
tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh core.sh service.sh
setup_runtime_paths "$tmpdir"
CLASH_BIN="$tmpdir/core"
RUNTIME_CONFIG="$PKG_TMP_DIR/config.yaml"
echo 'mode: rule' >"$CLASH_CONFIG"
settings_load() { :; }
settings_ensure_generated() { :; }
service_recover() { :; }
layout_init() { :; }
cron_update() { :; }
mihomo_config_key() { return 1; }
mihomo_config_generate() { cp "$1" "$2"; }
mihomo_memory_limit() { echo 128MiB; }
for scenario in settings validation geodata missing_core nonexec_core lock layout yaml_rejected generate_io; do
 (
  rm -f "$CONFIG_INVALID_FILE" "$CONFIG_TESTED_FILE" "$CORE_VERSION_CACHE"
  printf '#!/bin/sh\n[ "$1" != -v ] || { echo "Mihomo v1.2.3"; exit 0; }\nexit 0\n' >"$CLASH_BIN"
  chmod +x "$CLASH_BIN"
  with_lock() { "$@"; }
  expected=no
  case "$scenario" in
  settings) settings_load() { settings_invalid lists_interval x; }; expected=yes ;;
  validation | geodata)
   printf '#!/bin/sh\necho "%s" >&2\nexit 1\n' "$scenario rejected" >"$CLASH_BIN"
   expected=yes
   ;;
  missing_core) rm "$CLASH_BIN" ;;
  nonexec_core) chmod -x "$CLASH_BIN" ;;
  lock) with_lock() { echo 'Error: runtime lock timed out' >&2; return 1; } ;;
  layout) layout_init() { echo 'Error: layout failed' >&2; return 1; } ;;
  yaml_rejected) mihomo_config_generate() { return 2; }; expected=yes ;;
  generate_io) mihomo_config_generate() { return 1; } ;;
  esac
  if service_prepare_cmd 2>"$tmpdir/error"; then fail "$scenario must fail prepare"; fi
  if [ "$expected" = yes ]; then
   assert_true "$scenario blocks automatic restart" test -f "$CONFIG_INVALID_FILE"
  else
   assert_false "$scenario must not block automatic restart" test -e "$CONFIG_INVALID_FILE"
  fi
 )
 pass "configuration invalid marker: $scenario"
done
(
 load_modules mihomo-config.sh
 lan_ip_detect() { echo 192.0.2.1; }
 lists_profile_filter() { :; }
 printf 'dns: [broken\n' >"$tmpdir/broken.yaml"
 rc=0
 mihomo_config_generate "$tmpdir/broken.yaml" "$tmpdir/out.yaml" 2>/dev/null || rc=$?
 assert_eq 2 "$rc" 'generator rejection of the YAML returns 2'
 rc=0
 mihomo_config_generate "$tmpdir/missing.yaml" "$tmpdir/out.yaml" 2>/dev/null || rc=$?
 assert_eq 1 "$rc" 'unreadable source returns 1'
)
pass 'generator separates YAML rejection from other failures'
: >"$CONFIG_INVALID_FILE"
config_check_record ok
assert_false 'valid configuration clears invalid marker' test -e "$CONFIG_INVALID_FILE"
pass 'valid configuration clears invalid marker'
