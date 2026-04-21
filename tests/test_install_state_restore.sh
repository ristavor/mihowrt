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
backup_file_or_mark_missing "$tmpdir/absent.txt" "missing.txt"
[[ -f "$BACKUP_DIR/missing.txt.missing" ]] || fail "backup_file_or_mark_missing should record missing file tombstone"
restore_file_or_remove "missing.txt" "$missing_dst"
assert_false "restore_file_or_remove should preserve deleted user file state" test -e "$missing_dst"

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
assert_file_contains "$backup_log" "$DNS_BACKUP_FILE|$DNS_BACKUP_NAME" "backup_user_state should include DNS backup"

: > "$restore_log"
restore_user_state
assert_file_contains "$restore_log" "config.yaml|/opt/clash/config.yaml" "restore_user_state should restore config.yaml"
assert_file_contains "$restore_log" "mihowrt.uci|/etc/config/mihowrt" "restore_user_state should restore uci config"
assert_file_contains "$restore_log" "always_proxy_dst.txt|/opt/clash/lst/always_proxy_dst.txt" "restore_user_state should restore destination list"
assert_file_contains "$restore_log" "always_proxy_src.txt|/opt/clash/lst/always_proxy_src.txt" "restore_user_state should restore source list"

pass "installer backup and restore state helpers"
