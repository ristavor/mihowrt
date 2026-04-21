#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backup_path="$tmpdir/luci-app-mihowrt.config.yaml.bak"
live_config="$tmpdir/opt/clash/config.yaml"
script_path="$tmpdir/postinst.sh"

extract_postinst() {
	awk '
		$0=="define Package/$(PKG_NAME)/postinst" { in_block=1; next }
		in_block && $0=="endef" { exit }
		in_block { print }
	' "$ROOT_DIR/Makefile" |
		sed \
			-e "s|\$(PKG_CONFIG_BACKUP_FILE)|$backup_path|g" \
			-e "s|/opt/clash/config.yaml|$live_config|g" \
			-e 's|/usr/bin/mihowrt init-layout >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/mihowrt-recover enable >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/rpcd reload|true|g' \
			-e 's/\$\$/\$/g'
}

mkdir -p "$(dirname "$live_config")"

extract_postinst > "$script_path"
chmod +x "$script_path"

printf 'same-config\n' > "$backup_path"
printf 'same-config\n' > "$live_config"
touch -d '2024-01-01 00:00:00' "$live_config"
before_same_mtime="$(stat -c %Y "$live_config")"
IPKG_INSTROOT="" "$script_path"
after_same_mtime="$(stat -c %Y "$live_config")"
assert_eq "$before_same_mtime" "$after_same_mtime" "postinst should skip rewriting identical config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should remove identical config backup after skip"

printf 'new-config\n' > "$backup_path"
printf 'old-config\n' > "$live_config"
IPKG_INSTROOT="" "$script_path"
assert_file_contains "$live_config" "new-config" "postinst should restore changed config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should consume changed config backup"

pass "package hook snippets"
