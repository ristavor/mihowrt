#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backup_path="$tmpdir/luci-app-mihowrt.config.yaml.bak"
live_config="$tmpdir/opt/clash/config.yaml"
script_path="$tmpdir/postinst.sh"
prerm_path="$tmpdir/prerm.sh"
hook_log="$tmpdir/hook.log"
acl_file="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-mihowrt.json"

extract_hook() {
	local hook="$1"

	awk '
		$0=="define Package/$(PKG_NAME)/" hook { in_block=1; next }
		in_block && $0=="endef" { exit }
		in_block { print }
	' hook="$hook" "$ROOT_DIR/Makefile"
}

extract_postinst() {
	extract_hook "postinst" |
		sed \
			-e "s|\$(PKG_CONFIG_BACKUP_FILE)|$backup_path|g" \
			-e "s|/opt/clash/config.yaml|$live_config|g" \
			-e 's|/usr/bin/mihowrt init-layout >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/mihowrt-recover enable >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/rpcd reload|true|g' \
			-e 's/\$\$/\$/g'
}

extract_prerm() {
	extract_hook "prerm" |
		sed \
			-e "s|/etc/init.d/mihowrt-recover|$tmpdir/init-recover|g" \
			-e "s|/etc/init.d/mihowrt|$tmpdir/init-mihowrt|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g" \
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

extract_prerm > "$prerm_path"
chmod +x "$prerm_path"

cat > "$tmpdir/init-mihowrt" <<EOF
#!/usr/bin/env bash
printf 'init:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
cat > "$tmpdir/mihowrt" <<EOF
#!/usr/bin/env bash
printf 'mihowrt:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
cat > "$tmpdir/init-recover" <<EOF
#!/usr/bin/env bash
printf 'recover:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
chmod +x "$tmpdir/init-mihowrt" "$tmpdir/mihowrt" "$tmpdir/init-recover"

: > "$hook_log"
IPKG_INSTROOT="" "$prerm_path"
assert_file_contains "$hook_log" "init:stop" "prerm should stop service before package files are removed"
assert_file_contains "$hook_log" "mihowrt:cleanup" "prerm should clean runtime state before package files are removed"
assert_file_contains "$hook_log" "recover:disable" "prerm should disable recover init hook before package files are removed"

: > "$hook_log"
IPKG_INSTROOT="$tmpdir/root" "$prerm_path"
[[ ! -s "$hook_log" ]] || fail "prerm should skip host actions for offline root installs"

assert_eq "null" "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/bin/clash"] // null' "$acl_file")" "ACL should not allow direct Mihomo binary execution from LuCI"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/config.yaml"] // null' "$acl_file")" "ACL should not allow bypassing validated config apply"
assert_eq '["exec"]' "$(jq -c '."luci-app-mihowrt".write.file["/usr/bin/mihowrt"]' "$acl_file")" "ACL should keep validated backend execution"

pass "package hook snippets"
