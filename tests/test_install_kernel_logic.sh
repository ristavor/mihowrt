#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

asset_script="$tmpdir/asset-clash"
asset_gz="$tmpdir/asset-clash.gz"
kernel_log="$tmpdir/kernel.log"

source_install_lib

export CLASH_BIN="$tmpdir/clash"
export KERNEL_TMP_DIR="$tmpdir/kernel-update"
export KERNEL_LOG="$kernel_log"

log() {
	printf '%s\n' "$*" >>"$KERNEL_LOG"
}

detect_mihomo_arch() {
	printf 'amd64\n'
}

cat > "$asset_script" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
	printf 'Mihomo Meta v1.19.4\n'
fi
EOF
chmod +x "$asset_script"
gzip -c "$asset_script" > "$asset_gz"

write_kernel_script() {
	local path="$1"
	local version="$2"

	cat > "$path" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "-v" ]]; then
	printf 'Mihomo Meta v%s\n' '$version'
fi
EOF
	chmod +x "$path"
}

write_kernel_script "$CLASH_BIN" "1.19.4"

fetch_url() {
	printf '%s\n' '{"tag_name":"v1.19.4","assets":[{"browser_download_url":"https://example.com/mihomo-linux-amd64-v1.19.4.gz"}]}'
}

download_file() {
	fail "kernel_install_or_update should not download when kernel already current"
}

: > "$KERNEL_LOG"
kernel_install_or_update
assert_file_contains "$KERNEL_LOG" "Mihomo kernel already up to date (1.19.4)" "kernel_install_or_update should skip download for current kernel"

write_kernel_script "$CLASH_BIN" "1.19.3"

download_file() {
	cp "$asset_gz" "$2"
}

: > "$KERNEL_LOG"
kernel_install_or_update
assert_file_contains "$KERNEL_LOG" "Updated Mihomo kernel to v1.19.4 for arch amd64" "kernel_install_or_update should log successful upgrade"
assert_eq "v1.19.4" "$(current_mihomo_version)" "kernel_install_or_update should install downloaded kernel"
[[ -x "$CLASH_BIN.bak" ]] || fail "kernel_install_or_update should keep backup of previous kernel"
assert_eq "v1.19.3" "$("$CLASH_BIN.bak" -v | grep -oE '[vV]?[0-9]+\.[0-9]+\.[0-9]+' | head -n1)" "kernel_install_or_update should preserve previous kernel in backup"

write_kernel_script "$CLASH_BIN" "1.19.3"
write_kernel_script "$asset_script" "1.19.3"
gzip -c "$asset_script" > "$asset_gz"
write_kernel_script "$CLASH_BIN.bak" "0.0.1"
backup_before_identical_mtime="$(stat -c %Y "$CLASH_BIN.bak")"

: > "$KERNEL_LOG"
kernel_install_or_update
assert_file_contains "$KERNEL_LOG" "Downloaded Mihomo kernel is identical to installed binary" "kernel_install_or_update should skip replacing identical downloaded kernel"
assert_eq "v1.19.3" "$(current_mihomo_version)" "kernel_install_or_update should keep installed kernel when downloaded binary is identical"
backup_after_identical_mtime="$(stat -c %Y "$CLASH_BIN.bak")"
assert_eq "$backup_before_identical_mtime" "$backup_after_identical_mtime" "kernel_install_or_update should not rewrite backup when identical download is skipped"

write_kernel_script "$asset_script" "1.19.4"
gzip -c "$asset_script" > "$asset_gz"
write_kernel_script "$CLASH_BIN" "1.19.3"
cp "$CLASH_BIN" "$CLASH_BIN.bak"
touch -d '2024-01-01 00:00:00' "$CLASH_BIN.bak"
backup_before_upgrade_mtime="$(stat -c %Y "$CLASH_BIN.bak")"

: > "$KERNEL_LOG"
kernel_install_or_update
backup_after_upgrade_mtime="$(stat -c %Y "$CLASH_BIN.bak")"
assert_eq "$backup_before_upgrade_mtime" "$backup_after_upgrade_mtime" "kernel_install_or_update should skip rewriting identical backup copy"
assert_eq "v1.19.4" "$(current_mihomo_version)" "kernel_install_or_update should still install newer kernel when backup already matches current"

pass "installer kernel update branches"
