#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

tmpbin="$tmpdir/bin"
mkdir -p "$tmpbin"

cat > "$tmpbin/logger" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmpbin/uci" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_UCI_LOG"

if [[ "${1:-}" == "-q" ]]; then
	shift
fi

case "${1:-}" in
	get)
		case "${2:-}" in
			mihowrt.settings.enabled)
				[[ "${TEST_UCI_LEGACY_ENABLED+x}" == x ]] || exit 1
				printf '%s\n' "$TEST_UCI_LEGACY_ENABLED"
				;;
			mihowrt.settings.policy_mode)
				[[ "${TEST_UCI_POLICY_MODE+x}" == x ]] || exit 1
				printf '%s\n' "$TEST_UCI_POLICY_MODE"
				;;
			*)
				exit 1
				;;
		esac
		;;
	set|delete|commit)
		exit "${TEST_UCI_MUTATE_RC:-0}"
		;;
	*)
		exit 1
		;;
esac
EOF

chmod +x "$tmpbin/logger" "$tmpbin/uci"
export PATH="$tmpbin:$PATH"
export TEST_UCI_LOG="$tmpdir/uci.log"

source "$ROOT_DIR/rootfs/usr/lib/mihowrt/constants.sh"
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"

: >"$TEST_UCI_LOG"
export TEST_UCI_LEGACY_ENABLED=0
unset TEST_UCI_POLICY_MODE
migrate_legacy_uci_settings
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings=settings" "legacy migration should ensure settings section before setting policy mode"
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.policy_mode=direct-first" "legacy migration should force missing policy mode to direct-first"
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.enabled" "legacy migration should remove old enabled option"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "legacy migration should commit one UCI transaction"

: >"$TEST_UCI_LOG"
export TEST_UCI_LEGACY_ENABLED=1
export TEST_UCI_POLICY_MODE=proxy-first
migrate_legacy_uci_settings
assert_file_not_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.policy_mode=direct-first" "legacy migration should preserve explicit current policy mode"
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.enabled" "legacy migration should still remove old enabled option"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "legacy migration should commit legacy option removal"

: >"$TEST_UCI_LOG"
unset TEST_UCI_LEGACY_ENABLED
export TEST_UCI_POLICY_MODE=direct-first
migrate_legacy_uci_settings
assert_file_not_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.policy_mode=direct-first" "legacy migration should not rewrite current direct-first config"
assert_file_not_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.enabled" "legacy migration should not delete absent legacy option"
assert_file_not_contains "$TEST_UCI_LOG" "-q commit mihowrt" "legacy migration should avoid NAND write when nothing changes"

: >"$TEST_UCI_LOG"
export TEST_UCI_LEGACY_ENABLED=1
export TEST_UCI_POLICY_MODE=invalid-mode
migrate_legacy_uci_settings
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.policy_mode=direct-first" "legacy migration should force invalid policy mode to direct-first"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "legacy migration should commit invalid mode repair"
