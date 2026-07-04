#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"; rm -f /tmp/mihowrt-policy-list.test.*' EXIT

log_file="$tmpdir/policy-list-apply.log"
LIST_DIR="$tmpdir/lst"
DST_LIST_FILE="$LIST_DIR/always_proxy_dst.txt"
SRC_LIST_FILE="$LIST_DIR/always_proxy_src.txt"
DIRECT_DST_LIST_FILE="$LIST_DIR/direct_dst.txt"
PKG_TMP_DIR="$tmpdir/tmp"
mkdir -p "$LIST_DIR" "$PKG_TMP_DIR"

MIHOWRT_HELPERS_AUTOLOAD=0
# shellcheck disable=SC1090
. "$ROOT_DIR/rootfs/usr/lib/mihowrt/helpers.sh"
unset MIHOWRT_HELPERS_AUTOLOAD
# shellcheck disable=SC1090
. "$ROOT_DIR/rootfs/usr/lib/mihowrt/policy.sh"

err() {
	printf 'err:%s\n' "$*" >>"$log_file"
}

load_runtime_config() {
	printf 'load_runtime_config\n' >>"$log_file"
	return 0
}

service_running_state() {
	printf 'service_running_state\n' >>"$log_file"
	return "${TEST_SERVICE_RUNNING_RC:-0}"
}

policy_resolve_runtime_lists_without_cache() {
	printf 'validate:%s|%s|%s\n' "$POLICY_DST_LIST_FILE" "$POLICY_SRC_LIST_FILE" "$POLICY_DIRECT_DST_LIST_FILE" >>"$log_file"
	return "${TEST_VALIDATE_RC:-0}"
}

reload_runtime_state() {
	printf 'reload_runtime_state\n' >>"$log_file"
	return "${TEST_RELOAD_RC:-0}"
}

candidate_file() {
	local name="$1" value="$2" path=""

	path="$(mktemp "/tmp/mihowrt-policy-list.test.$name.XXXXXX")"
	printf '%s' "$value" >"$path"
	printf '%s\n' "$path"
}

: >"$DST_LIST_FILE"
printf '1.1.1.1\n' >"$DST_LIST_FILE"
printf '10.0.0.1\n' >"$SRC_LIST_FILE"
printf '8.8.8.8\n' >"$DIRECT_DST_LIST_FILE"

: >"$log_file"
dst_candidate="$(candidate_file dst '1.1.1.1
')"
src_candidate="$(candidate_file src '10.0.0.1
')"
direct_candidate="$(candidate_file direct '8.8.8.8
')"
result="$(apply_policy_lists_runtime 1 "$dst_candidate" "$src_candidate" "$direct_candidate")"
assert_eq "false" "$(printf '%s' "$result" | jq -r '.changed')" "apply_policy_lists_runtime should report unchanged content without NAND writes"
assert_eq "false" "$(printf '%s' "$result" | jq -r '.reloaded')" "apply_policy_lists_runtime should skip reload when files did not change"
assert_file_not_contains "$log_file" "reload_runtime_state" "apply_policy_lists_runtime should not reload unchanged lists"

: >"$log_file"
dst_candidate="$(candidate_file dst '2.2.2.2
')"
src_candidate="$(candidate_file src '10.0.0.1
')"
direct_candidate="$(candidate_file direct '8.8.8.8
')"
result="$(apply_policy_lists_runtime 1 "$dst_candidate" "$src_candidate" "$direct_candidate")"
assert_eq "true" "$(printf '%s' "$result" | jq -r '.changed')" "apply_policy_lists_runtime should report changed content"
assert_eq "true" "$(printf '%s' "$result" | jq -r '.reloaded')" "apply_policy_lists_runtime should reload changed lists when service is running"
assert_file_contains "$DST_LIST_FILE" "2.2.2.2" "apply_policy_lists_runtime should install changed destination list"
assert_file_contains "$log_file" "reload_runtime_state" "apply_policy_lists_runtime should reload changed runtime policy"
[[ ! -e "$dst_candidate" && ! -e "$src_candidate" && ! -e "$direct_candidate" ]] || fail "apply_policy_lists_runtime should remove temp candidates after success"

: >"$log_file"
dst_candidate="$(candidate_file dst '2.2.2.2
')"
src_candidate="$(candidate_file src '10.0.0.2
')"
direct_candidate="$(candidate_file direct '8.8.8.8
')"
result="$(apply_policy_lists_runtime 1 "$dst_candidate" "$src_candidate" "$direct_candidate")"
assert_eq "true" "$(printf '%s' "$result" | jq -r '.changed')" "apply_policy_lists_runtime should report changed source content"
assert_eq "true" "$(printf '%s' "$result" | jq -r '.reloaded')" "apply_policy_lists_runtime should reload changed source list when service is running"
assert_file_contains "$SRC_LIST_FILE" "10.0.0.2" "apply_policy_lists_runtime should install changed source list"
assert_file_contains "$log_file" "reload_runtime_state" "apply_policy_lists_runtime should reload source-list changes"

: >"$log_file"
dst_candidate="$(candidate_file dst '2.2.2.2
')"
src_candidate="$(candidate_file src '10.0.0.3
')"
direct_candidate="$(candidate_file direct '8.8.8.8
')"
TEST_RELOAD_RC=1 assert_false "apply_policy_lists_runtime should fail when reload fails" apply_policy_lists_runtime 1 "$dst_candidate" "$src_candidate" "$direct_candidate"
assert_file_contains "$SRC_LIST_FILE" "10.0.0.2" "apply_policy_lists_runtime should restore previous source list after reload failure"
assert_file_not_contains "$SRC_LIST_FILE" "10.0.0.3" "apply_policy_lists_runtime should not leave failed source list on NAND"
unset TEST_RELOAD_RC

: >"$log_file"
dst_candidate="$(candidate_file dst '')"
src_candidate="$(candidate_file src '10.0.0.2
')"
direct_candidate="$(candidate_file direct '8.8.8.8
')"
result="$(apply_policy_lists_runtime 0 "$dst_candidate" "$src_candidate" "$direct_candidate")"
assert_eq "true" "$(printf '%s' "$result" | jq -r '.changed')" "apply_policy_lists_runtime should report deletion as changed"
[[ ! -e "$DST_LIST_FILE" ]] || fail "apply_policy_lists_runtime should remove empty destination list"
assert_file_not_contains "$log_file" "reload_runtime_state" "apply_policy_lists_runtime should not reload when reload flag is off"

pass "policy list apply"
