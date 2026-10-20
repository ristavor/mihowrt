#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

setup_fake_uci "$tmpdir"
load_modules constants.sh helpers.sh validate.sh settings.sh mihomo-config.sh mihomo-api.sh config.sh
PKG_TMP_DIR="$tmpdir/tmp"
CLASH_DIR="$tmpdir/clash"
CLASH_CONFIG="$CLASH_DIR/config.yaml"
CLASH_CONFIG_BACKUP="$CLASH_DIR/config.yaml.bak"
RUNTIME_CONFIG="$tmpdir/runtime.yaml"
mkdir -p "$CLASH_DIR"
CLASH_BIN="$tmpdir/clash-bin"
cat >"$CLASH_BIN" <<'C'
#!/bin/sh
if grep -q BROKEN "$4"; then echo "level=error msg=\"proxy 0: missing type\""; exit 1; fi
exit 0
C
chmod +x "$CLASH_BIN"
echo "mode: rule" >"$CLASH_CONFIG"
running=0
service_running() { [ "$running" = 1 ]; }
service_ready() { [ "$running" = 1 ]; }
runtime_config_build() { mihomo_config_generate "$CLASH_CONFIG" "$1"; }
reload_ok=1
api_reload() { [ "$reload_ok" = 1 ]; }

echo BROKEN >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>"$tmpdir/err"; then fail "invalid config must be rejected"; fi
assert_eq "mode: rule" "$(cat "$CLASH_CONFIG")" "source unchanged"
assert_file_contains "$tmpdir/err" "missing type" "Mihomo error passed to the user"
pass "save rejects invalid"

echo "mode: global" >"$tmpdir/cand"
assert_eq '{"action":"saved"}' "$(config_install "$tmpdir/cand")" "saved while stopped"
assert_eq "mode: global" "$(cat "$CLASH_CONFIG")" "installed"
assert_eq "mode: rule" "$(cat "$CLASH_CONFIG_BACKUP")" "backup kept"
pass "save while stopped"

running=1
echo "mode: direct" >"$tmpdir/cand"
assert_eq '{"action":"hot_reloaded"}' "$(config_install "$tmpdir/cand")" "hot reload while running"
pass "hot reload"

reload_ok=0
echo "log-level: debug" >"$tmpdir/cand"
if config_install "$tmpdir/cand" 2>/dev/null; then fail "failed reload must fail"; fi
assert_eq "mode: direct" "$(cat "$CLASH_CONFIG")" "previous config restored"
pass "apply rollback"

assert_false "path outside tmp" config_temp_path_allowed /etc/hosts
assert_false "nested path" config_temp_path_allowed /tmp/mihowrt-config.x/y
link="/tmp/mihowrt-config.testlink.$$"
ln -s /etc/hosts "$link"
assert_false "symlink" config_temp_path_allowed "$link"
rm -f "$link"
assert_eq "mode: direct" "$(config_read_json | jq -r .content | head -n1)" "read config"
pass "config paths"

# D: saving while Mihomo is still starting waits for readiness, no rollback.
service_running() { return 0; }
starting=1
api_reload() { [ "$starting" = 0 ]; }
service_ready() { starting=0; return 0; }
echo "mode: rule" >"$CLASH_CONFIG"
echo "mode: global" >"$tmpdir/cand"
config_install "$tmpdir/cand" >/dev/null 2>&1 || true
assert_eq "mode: global" "$(cat "$CLASH_CONFIG")" "config kept when saved during startup"
pass "save during startup"
