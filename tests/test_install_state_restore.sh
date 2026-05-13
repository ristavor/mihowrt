#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

copy_src="$tmpdir/source.txt"
copy_dst="$tmpdir/dest/output.txt"
backup_log="$tmpdir/backup.log"
restore_log="$tmpdir/restore.log"

source_install_lib

BACKUP_DIR="$tmpdir/backup"
mkdir -p "$BACKUP_DIR"

printf 'user-data\n' > "$copy_src"
backup_file "$copy_src" "copy.txt"
assert_file_contains "$BACKUP_DIR/copy.txt" "user-data" "backup_file should copy existing file"

restore_file "copy.txt" "$copy_dst"
assert_file_contains "$copy_dst" "user-data" "restore_file should restore backed up file"

copy_same_dst="$tmpdir/dest/same-output.txt"
printf 'same-data\n' > "$BACKUP_DIR/same.txt"
printf 'same-data\n' > "$copy_same_dst"
touch -d '2020-01-01 00:00:00' "$BACKUP_DIR/same.txt"
touch -d '2024-01-01 00:00:00' "$copy_same_dst"
before_same_mtime="$(stat -c %Y "$copy_same_dst")"
restore_file "same.txt" "$copy_same_dst"
after_same_mtime="$(stat -c %Y "$copy_same_dst")"
assert_eq "$before_same_mtime" "$after_same_mtime" "restore_file should skip rewriting identical persistent files"

missing_dst="$tmpdir/dest/missing-output.txt"
printf 'to-be-removed\n' > "$missing_dst"
# shellcheck disable=SC2218
backup_file_or_mark_missing "$tmpdir/absent.txt" "missing.txt"
[[ -f "$BACKUP_DIR/missing.txt.missing" ]] || fail "backup_file_or_mark_missing should record missing file tombstone"
# shellcheck disable=SC2218
restore_file_or_remove "missing.txt" "$missing_dst"
assert_false "restore_file_or_remove should preserve deleted user file state" test -e "$missing_dst"

backup_file() {
	return 1
}

assert_false "backup_file_or_mark_missing should fail when backup copy fails" backup_file_or_mark_missing "$copy_src" "broken.txt"

release_reinstall_dependencies() {
	:
}

warn() {
	:
}

preserved_backup_dir="$tmpdir/preserved-backup"
mkdir -p "$preserved_backup_dir"
BACKUP_DIR="$preserved_backup_dir"
PRESERVE_BACKUP_DIR=0
preserve_backup_dir
cleanup
assert_true "cleanup should keep preserved backup directory" test -d "$preserved_backup_dir"

preserved_kernel_dir="$tmpdir/preserved-kernel"
mkdir -p "$preserved_kernel_dir"
KERNEL_TMP_DIR="$preserved_kernel_dir"
KERNEL_BACKUP_TMP="$preserved_kernel_dir/clash.previous"
printf 'kernel\n' > "$KERNEL_BACKUP_TMP"
PRESERVE_KERNEL_TMP_DIR=0
preserve_kernel_backup_dir
cleanup
assert_true "cleanup should keep preserved kernel backup directory" test -d "$preserved_kernel_dir"
assert_true "cleanup should keep preserved kernel backup file" test -f "$preserved_kernel_dir/clash.previous"

create_backup_dir() {
	BACKUP_DIR="$tmpdir/backup-user-state"
	mkdir -p "$BACKUP_DIR"
}

backup_file_or_mark_missing() {
	printf '%s|%s\n' "$1" "$2" >>"$backup_log"
}

restore_file_or_remove() {
	printf '%s|%s\n' "$1" "$2" >>"$restore_log"
}

: > "$backup_log"
export DNS_BACKUP_FILE="$tmpdir/dns.backup"
export DNS_BACKUP_NAME="dns.backup"
backup_user_state
assert_file_contains "$backup_log" "/opt/clash/config.yaml|config.yaml" "backup_user_state should include config.yaml"
assert_file_contains "$backup_log" "/etc/config/mihowrt|mihowrt.uci" "backup_user_state should include uci config"
assert_file_contains "$backup_log" "/opt/clash/lst/always_proxy_dst.txt|always_proxy_dst.txt" "backup_user_state should include destination list"
assert_file_contains "$backup_log" "/opt/clash/lst/always_proxy_src.txt|always_proxy_src.txt" "backup_user_state should include source list"
assert_file_contains "$backup_log" "/opt/clash/lst/direct_dst.txt|direct_dst.txt" "backup_user_state should include direct destination list"
assert_file_contains "$backup_log" "$DNS_BACKUP_FILE|$DNS_BACKUP_NAME" "backup_user_state should include DNS backup"

: > "$restore_log"
restore_user_state
assert_file_contains "$restore_log" "config.yaml|/opt/clash/config.yaml" "restore_user_state should restore config.yaml"
assert_file_contains "$restore_log" "mihowrt.uci|/etc/config/mihowrt" "restore_user_state should restore uci config"
assert_file_contains "$restore_log" "always_proxy_dst.txt|/opt/clash/lst/always_proxy_dst.txt" "restore_user_state should restore destination list"
assert_file_contains "$restore_log" "always_proxy_src.txt|/opt/clash/lst/always_proxy_src.txt" "restore_user_state should restore source list"
assert_file_contains "$restore_log" "direct_dst.txt|/opt/clash/lst/direct_dst.txt" "restore_user_state should restore direct destination list"

create_backup_dir() {
	printf 'create_backup_dir\n' >>"$backup_log"
	return 1
}

backup_file_or_mark_missing() {
	printf 'backup:%s|%s\n' "$1" "$2" >>"$backup_log"
	return 0
}

: > "$backup_log"
assert_false "backup_user_state should fail when create_backup_dir fails" backup_user_state
assert_file_contains "$backup_log" "create_backup_dir" "backup_user_state should attempt to create backup dir first"
assert_file_not_contains "$backup_log" "backup:/opt/clash/config.yaml|config.yaml" "backup_user_state should stop after create_backup_dir failure"

create_backup_dir() {
	printf 'create_backup_dir\n' >>"$backup_log"
	BACKUP_DIR="$tmpdir/backup-short-circuit"
	mkdir -p "$BACKUP_DIR"
}

backup_fail_count=0
backup_file_or_mark_missing() {
	backup_fail_count=$((backup_fail_count + 1))
	printf 'backup:%s|%s\n' "$1" "$2" >>"$backup_log"
	[ "$backup_fail_count" -eq 1 ] && return 1
	return 0
}

: > "$backup_log"
assert_false "backup_user_state should fail on first backup write error" backup_user_state
assert_eq "1" "$backup_fail_count" "backup_user_state should stop after first backup write error"

restore_fail_count=0
restore_file_or_remove() {
	restore_fail_count=$((restore_fail_count + 1))
	printf 'restore:%s|%s\n' "$1" "$2" >>"$restore_log"
	[ "$restore_fail_count" -eq 1 ] && return 1
	return 0
}

: > "$restore_log"
assert_false "restore_user_state should fail on first restore error" restore_user_state
assert_eq "1" "$restore_fail_count" "restore_user_state should stop after first restore error"

pass "installer backup and restore state helpers"
