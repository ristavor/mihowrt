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
			mihowrt.settings.route_table_id)
				[[ "${TEST_UCI_ROUTE_TABLE_ID+x}" == x ]] || exit 1
				printf '%s\n' "$TEST_UCI_ROUTE_TABLE_ID"
				;;
			mihowrt.settings.route_rule_priority)
				[[ "${TEST_UCI_ROUTE_RULE_PRIORITY+x}" == x ]] || exit 1
				printf '%s\n' "$TEST_UCI_ROUTE_RULE_PRIORITY"
				;;
			mihowrt.settings.policy_remote_update_interval)
				[[ "${TEST_UCI_POLICY_REMOTE_INTERVAL+x}" == x ]] || exit 1
				printf '%s\n' "$TEST_UCI_POLICY_REMOTE_INTERVAL"
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
source "$ROOT_DIR/rootfs/usr/lib/mihowrt/lists.sh"

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
export TEST_UCI_ROUTE_TABLE_ID=201
export TEST_UCI_ROUTE_RULE_PRIORITY=10010
migrate_legacy_uci_settings
assert_file_contains "$TEST_UCI_LOG" "-q set mihowrt.settings.policy_mode=direct-first" "legacy migration should force invalid policy mode to direct-first"
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.route_table_id" "legacy migration should remove obsolete route table overrides"
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.route_rule_priority" "legacy migration should remove obsolete route priority overrides"
assert_file_contains "$TEST_UCI_LOG" "-q commit mihowrt" "legacy migration should commit invalid mode repair"
unset TEST_UCI_ROUTE_TABLE_ID TEST_UCI_ROUTE_RULE_PRIORITY

DST_LIST_FILE="$tmpdir/always_proxy_dst.txt"
SRC_LIST_FILE="$tmpdir/always_proxy_src.txt"
DIRECT_DST_LIST_FILE="$tmpdir/direct_dst.txt"
printf '1.1.1.1\nhttps://example.com/dst.txt\nhttps://example.com/existing.txt | 12\n' >"$DST_LIST_FILE"
printf 'https://example.com/src.txt;0443\n' >"$SRC_LIST_FILE"
: >"$DIRECT_DST_LIST_FILE"
export TEST_UCI_POLICY_REMOTE_INTERVAL=6
: >"$TEST_UCI_LOG"
migrate_policy_remote_intervals
assert_file_contains "$DST_LIST_FILE" "https://example.com/dst.txt | 6" "remote list migration should preserve the old global interval per URL"
assert_file_contains "$DST_LIST_FILE" "https://example.com/existing.txt | 12" "remote list migration should preserve an existing per-URL interval"
assert_file_contains "$SRC_LIST_FILE" "https://example.com/src.txt;0443 | 6" "remote list migration should preserve URL port scope"
assert_file_contains "$TEST_UCI_LOG" "-q delete mihowrt.settings.policy_remote_update_interval" "remote list migration should remove the obsolete global interval"
unset TEST_UCI_POLICY_REMOTE_INTERVAL

: >"$TEST_UCI_LOG"
unset TEST_UCI_LEGACY_ENABLED
export TEST_UCI_POLICY_MODE=direct-first
migrate_policy_list_files() {
	printf 'policy-list-migrated\n' >>"$TEST_UCI_LOG"
}
migrate_all
assert_file_contains "$TEST_UCI_LOG" "policy-list-migrated" "migrate_all should run policy list migrations after UCI migrations"
assert_file_not_contains "$TEST_UCI_LOG" "-q commit mihowrt" "migrate_all should not commit UCI config when legacy settings are already current"
