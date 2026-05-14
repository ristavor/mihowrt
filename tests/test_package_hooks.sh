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
skip_start="$tmpdir/skip-start"
acl_file="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-mihowrt.json"
keep_file="$ROOT_DIR/rootfs/lib/upgrade/keep.d/mihowrt"

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
			-e "s|/tmp/luci-app-mihowrt.skip-start|$skip_start|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g" \
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

extract_hook "postinst" >"$tmpdir/postinst.raw"
assert_file_contains "$tmpdir/postinst.raw" "/tmp/luci-app-mihowrt.skip-start" "postinst should detect installer transactions"
assert_file_contains "$tmpdir/postinst.raw" "/usr/bin/mihowrt migrate-legacy-settings" "postinst should migrate legacy UCI settings on package upgrade"
assert_file_contains "$tmpdir/postinst.raw" "/usr/bin/mihowrt migrate-policy-lists" "postinst should migrate legacy policy list syntax on package upgrade"

cat >"$tmpdir/mihowrt" <<EOF
#!/usr/bin/env bash
printf 'mihowrt:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
chmod +x "$tmpdir/mihowrt"

extract_postinst >"$script_path"
chmod +x "$script_path"

printf 'same-config\n' >"$backup_path"
printf 'same-config\n' >"$live_config"
touch -d '2024-01-01 00:00:00' "$live_config"
before_same_mtime="$(stat -c %Y "$live_config")"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
after_same_mtime="$(stat -c %Y "$live_config")"
assert_eq "$before_same_mtime" "$after_same_mtime" "postinst should skip rewriting identical config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should remove identical config backup after skip"
assert_file_contains "$hook_log" "mihowrt:migrate-legacy-settings" "postinst should migrate legacy settings outside installer transaction"
assert_file_contains "$hook_log" "mihowrt:migrate-policy-lists" "postinst should migrate policy lists outside installer transaction"

printf 'new-config\n' >"$backup_path"
printf 'old-config\n' >"$live_config"
IPKG_INSTROOT="" "$script_path"
assert_file_contains "$live_config" "new-config" "postinst should restore changed config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should consume changed config backup"

printf 'skip-config\n' >"$backup_path"
printf 'skip-config\n' >"$live_config"
: >"$skip_start"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
assert_file_not_contains "$hook_log" "mihowrt:migrate-legacy-settings" "postinst should defer legacy settings migration during installer transaction"
assert_file_not_contains "$hook_log" "mihowrt:migrate-policy-lists" "postinst should defer policy list migration during installer transaction"
assert_file_contains "$hook_log" "mihowrt:init-layout" "postinst should still initialize layout during installer transaction"
rm -f "$skip_start"

extract_prerm >"$prerm_path"
chmod +x "$prerm_path"

cat >"$tmpdir/init-mihowrt" <<EOF
#!/usr/bin/env bash
printf 'init:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
cat >"$tmpdir/mihowrt" <<EOF
#!/usr/bin/env bash
printf 'mihowrt:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
cat >"$tmpdir/init-recover" <<EOF
#!/usr/bin/env bash
printf 'recover:%s\n' "\$*" >>"$hook_log"
exit 0
EOF
chmod +x "$tmpdir/init-mihowrt" "$tmpdir/mihowrt" "$tmpdir/init-recover"

: >"$hook_log"
IPKG_INSTROOT="" "$prerm_path"
assert_file_contains "$hook_log" "init:stop" "prerm should stop service before package files are removed"
assert_file_contains "$hook_log" "mihowrt:cleanup" "prerm should clean runtime state before package files are removed"
assert_file_contains "$hook_log" "recover:disable" "prerm should disable recover init hook before package files are removed"

: >"$hook_log"
IPKG_INSTROOT="$tmpdir/root" "$prerm_path"
[[ ! -s "$hook_log" ]] || fail "prerm should skip host actions for offline root installs"

assert_eq "null" "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/bin/clash"] // null' "$acl_file")" "ACL should not allow direct Mihomo binary execution from LuCI"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/config.yaml"] // null' "$acl_file")" "ACL should not allow bypassing validated config apply"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".read.file["/usr/bin/mihowrt"] // null' "$acl_file")" "ACL read scope should not execute mutating backend"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".read.file["/etc/init.d/mihowrt"] // null' "$acl_file")" "ACL read scope should not execute init service script"
assert_eq '["exec"]' "$(jq -c '."luci-app-mihowrt".read.file["/usr/bin/mihowrt-read"]' "$acl_file")" "ACL read scope should execute only read-only backend wrapper"
assert_eq '["exec"]' "$(jq -c '."luci-app-mihowrt".write.file["/usr/bin/mihowrt"]' "$acl_file")" "ACL should keep validated backend execution"
assert_eq '["write"]' "$(jq -c '."luci-app-mihowrt".write.file["/tmp/mihowrt-config.*"]' "$acl_file")" "ACL should allow only MihoWRT temp config staging from LuCI"
assert_eq '["read"]' "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/direct_dst.txt"]' "$acl_file")" "ACL should allow reading direct destination list"
assert_eq '["write"]' "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/lst/direct_dst.txt"]' "$acl_file")" "ACL should allow writing direct destination list"

assert_file_contains "$ROOT_DIR/Makefile" "\$(1)/lib/upgrade/keep.d" "package should install sysupgrade keep directory"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/usr/bin/mihowrt-read' "package should install read-only backend wrapper"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/lib/upgrade/keep.d/mihowrt' "package should install MihoWRT sysupgrade keep list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/view/mihowrt/*' "package should install LuCI view assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/mihowrt/*' "package should install LuCI helper assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -f /tmp/luci-indexcache' "postinst should clear LuCI index cache after upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -rf /tmp/luci-modulecache' "postinst should clear LuCI module cache after upgrade"
assert_file_contains "$ROOT_DIR/Makefile" '/opt/clash/lst/direct_dst.txt' "package conffiles should include direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/clash/lst/direct_dst.txt' "package should install direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" '/opt/clash/mihomo.sock' "package removal should delete Mihomo socket symlink"
assert_file_contains "$ROOT_DIR/Makefile" '# mihowrt subscription auto-update' "package removal should delete subscription cron entry"
assert_file_contains "$ROOT_DIR/Makefile" '# mihowrt policy remote auto-update' "package removal should delete policy remote cron entry"
assert_file_contains "$ROOT_DIR/Makefile" '+@wget-any' "package should depend on wget provider for subscription downloads"
assert_file_contains "$ROOT_DIR/Makefile" '+curl' "package should depend on curl for Mihomo API hot reload"
assert_file_contains "$ROOT_DIR/install.sh" 'REQUIRED_REPO_PACKAGES="luci-base nftables jq kmod-nft-tproxy wget-any curl"' "installer dependency hold should include wget provider and curl"
assert_file_contains "$ROOT_DIR/install.sh" '/usr/bin/mihowrt-read' "installer removal should delete read-only backend wrapper"
assert_file_contains "$ROOT_DIR/install.sh" '/opt/clash/mihomo.sock' "installer removal should delete Mihomo socket symlink"
assert_file_contains "$ROOT_DIR/install.sh" '# mihowrt subscription auto-update' "installer removal should delete subscription cron entry"
assert_file_contains "$ROOT_DIR/install.sh" '# mihowrt policy remote auto-update' "installer removal should delete policy remote cron entry"
assert_file_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "option subscription_url ''" "default UCI config should disable subscriptions"
assert_file_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "option policy_remote_update_interval '0'" "default UCI config should disable policy remote auto-updates"
assert_file_contains "$keep_file" "/etc/config/mihowrt" "sysupgrade keep list should preserve UCI config"
assert_file_contains "$keep_file" "/etc/mihowrt" "sysupgrade keep list should preserve persistent MihoWRT state"
assert_file_contains "$keep_file" "/opt/clash/config.yaml" "sysupgrade keep list should preserve Mihomo config"
assert_file_contains "$keep_file" "/opt/clash/lst" "sysupgrade keep list should preserve policy lists"
assert_file_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/mihowrt.list" "/opt/clash/lst/direct_dst.txt" "APK protected paths should preserve direct destination list"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/mihowrt.list" "/www/luci-static" "APK protected paths should not preserve stale LuCI assets"

pass "package hook snippets"
