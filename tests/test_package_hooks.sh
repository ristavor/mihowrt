#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/testlib.sh"

tmpdir="$(make_temp_dir)"
trap 'rm -rf "$tmpdir"' EXIT

backup_path="$tmpdir/luci-app-mihowrt.config.yaml.bak"
list_backup_dir="$tmpdir/luci-app-mihowrt.policy-lists.bak"
live_config="$tmpdir/opt/clash/config.yaml"
live_list_dir="$tmpdir/opt/clash/lst"
live_dst_list="$live_list_dir/always_proxy_dst.txt"
live_src_list="$live_list_dir/always_proxy_src.txt"
live_direct_list="$live_list_dir/direct_dst.txt"
live_direct_src_list="$live_list_dir/direct_src.txt"
preinst_path="$tmpdir/preinst.sh"
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

rewrite_package_paths() {
	sed \
		-e "s|\$(PKG_CONFIG_BACKUP_FILE)|$backup_path|g" \
		-e "s|\$(PKG_POLICY_LIST_BACKUP_DIR)|$list_backup_dir|g" \
		-e "s|/opt/clash/config.yaml|$live_config|g" \
		-e "s|/opt/clash/lst/always_proxy_dst.txt|$live_dst_list|g" \
		-e "s|/opt/clash/lst/always_proxy_src.txt|$live_src_list|g" \
		-e "s|/opt/clash/lst/direct_dst.txt|$live_direct_list|g" \
		-e "s|/opt/clash/lst/direct_src.txt|$live_direct_src_list|g" \
		-e 's/\$\$/\$/g'
}

extract_preinst() {
	extract_hook "preinst" |
		rewrite_package_paths |
		sed -e "s|/tmp/luci-app-mihowrt.skip-start|$skip_start|g"
}

extract_postinst() {
	extract_hook "postinst" |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-mihowrt.skip-start|$skip_start|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g" \
			-e 's|/etc/init.d/mihowrt-recover enable >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/rpcd reload|true|g'
}

extract_prerm() {
	extract_hook "prerm" |
		sed \
			-e "s|/etc/init.d/mihowrt-recover|$tmpdir/init-recover|g" \
			-e "s|/etc/init.d/mihowrt|$tmpdir/init-mihowrt|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g" \
			-e 's/\$\$/\$/g'
}

mkdir -p "$(dirname "$live_config")" "$live_list_dir"

extract_hook "preinst" >"$tmpdir/preinst.raw"
assert_file_contains "$tmpdir/preinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)' "preinst should stage policy list backups before package payload install"
assert_file_contains "$tmpdir/preinst.raw" "backup_mihowrt_file" "preinst should use fail-fast backup helper"
assert_file_contains "$tmpdir/preinst.raw" "/opt/clash/lst/always_proxy_dst.txt" "preinst should back up destination policy list"
assert_file_contains "$tmpdir/preinst.raw" "/opt/clash/lst/always_proxy_src.txt" "preinst should back up source policy list"
assert_file_contains "$tmpdir/preinst.raw" "/opt/clash/lst/direct_dst.txt" "preinst should back up direct destination policy list"
extract_hook "postinst" >"$tmpdir/postinst.raw"
assert_file_contains "$tmpdir/postinst.raw" "/tmp/luci-app-mihowrt.skip-start" "postinst should clear the skip marker"
assert_file_contains "$tmpdir/postinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_dst.txt' "postinst should restore destination policy list backup"
assert_file_contains "$tmpdir/postinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_src.txt' "postinst should restore source policy list backup"
assert_file_contains "$tmpdir/postinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)/direct_dst.txt' "postinst should restore direct destination policy list backup"
assert_file_contains "$tmpdir/postinst.raw" "/usr/bin/mihowrt migrate" "postinst should run package migrations on package upgrade"

cat >"$tmpdir/mihowrt" <<EOF
#!/usr/bin/env bash
printf 'mihowrt:%s\n' "\$*" >>"$hook_log"
if [[ "\${1:-}" == "migrate" && "\${TEST_FAIL_MIGRATE:-0}" == "1" ]]; then
	exit 1
fi
exit 0
EOF
chmod +x "$tmpdir/mihowrt"

extract_preinst >"$preinst_path"
chmod +x "$preinst_path"
extract_postinst >"$script_path"
chmod +x "$script_path"

failbin="$tmpdir/failbin"
mkdir -p "$failbin"
cat >"$failbin/cp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$failbin/cp"

printf 'backup-fail-config\n' >"$live_config"
rm -f "$backup_path"
rm -rf "$list_backup_dir"
set +e
PATH="$failbin:$PATH" IPKG_INSTROOT="" "$preinst_path"
preinst_fail_rc=$?
set -e
[[ "$preinst_fail_rc" -ne 0 ]] || fail "preinst should fail when existing config cannot be backed up"
[[ ! -e "$backup_path" ]] || fail "preinst should not leave partial config backup after failed copy"

printf 'user-config\n' >"$live_config"
printf 'user-dst\n' >"$live_dst_list"
printf 'user-src\n' >"$live_src_list"
printf 'user-direct\n' >"$live_direct_list"
printf 'user-device\n' >"$live_direct_src_list"
IPKG_INSTROOT="" "$preinst_path"
assert_file_contains "$backup_path" "user-config" "preinst should back up existing config before fresh package install"
assert_file_contains "$list_backup_dir/always_proxy_dst.txt" "user-dst" "preinst should back up existing destination policy list"
assert_file_contains "$list_backup_dir/always_proxy_src.txt" "user-src" "preinst should back up existing source policy list"
assert_file_contains "$list_backup_dir/direct_dst.txt" "user-direct" "preinst should back up existing direct destination policy list"

printf 'package-config\n' >"$live_config"
printf 'package-dst\n' >"$live_dst_list"
printf 'package-src\n' >"$live_src_list"
printf 'package-direct\n' >"$live_direct_list"
printf 'package-device\n' >"$live_direct_src_list"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
assert_file_contains "$live_config" "user-config" "postinst should restore config preserved across sysupgrade reinstall"
assert_file_contains "$live_dst_list" "user-dst" "postinst should restore destination policy list preserved across sysupgrade reinstall"
assert_file_contains "$live_src_list" "user-src" "postinst should restore source policy list preserved across sysupgrade reinstall"
assert_file_contains "$live_direct_list" "user-direct" "postinst should restore direct destination policy list preserved across sysupgrade reinstall"
[[ ! -e "$backup_path" ]] || fail "postinst should consume restored config backup"
[[ ! -e "$list_backup_dir/always_proxy_dst.txt" ]] || fail "postinst should consume restored destination policy list backup"
[[ ! -e "$list_backup_dir/always_proxy_src.txt" ]] || fail "postinst should consume restored source policy list backup"
[[ ! -e "$list_backup_dir/direct_dst.txt" ]] || fail "postinst should consume restored direct destination policy list backup"
assert_file_contains "$live_direct_src_list" user-device "fourth list restored"
[[ ! -d "$list_backup_dir" ]] || fail "postinst should remove empty policy list backup directory"

printf 'same-config\n' >"$backup_path"
printf 'same-config\n' >"$live_config"
mkdir -p "$list_backup_dir"
printf 'same-dst\n' >"$list_backup_dir/always_proxy_dst.txt"
printf 'same-dst\n' >"$live_dst_list"
touch -d '2024-01-01 00:00:00' "$live_config"
touch -d '2024-01-01 00:00:00' "$live_dst_list"
file_mtime() {
	stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

before_same_mtime="$(file_mtime "$live_config")"
before_same_list_mtime="$(file_mtime "$live_dst_list")"
: >"$hook_log"
IPKG_INSTROOT="" "$script_path"
after_same_mtime="$(file_mtime "$live_config")"
after_same_list_mtime="$(file_mtime "$live_dst_list")"
assert_eq "$before_same_mtime" "$after_same_mtime" "postinst should skip rewriting identical config backup"
assert_eq "$before_same_list_mtime" "$after_same_list_mtime" "postinst should skip rewriting identical policy list backup"
[[ ! -e "$backup_path" ]] || fail "postinst should remove identical config backup after skip"
[[ ! -e "$list_backup_dir/always_proxy_dst.txt" ]] || fail "postinst should remove identical policy list backup after skip"
assert_file_contains "$hook_log" "mihowrt:migrate" "postinst should run migrations"

: >"$hook_log"
set +e
TEST_FAIL_MIGRATE=1 IPKG_INSTROOT="" "$script_path"
postinst_migrate_fail_rc=$?
set -e
[[ "$postinst_migrate_fail_rc" -ne 0 ]] || fail "postinst should fail when package migration fails"
assert_file_contains "$hook_log" "mihowrt:migrate" "postinst should attempt package migration before failing"

printf 'new-config\n' >"$backup_path"
printf 'old-config\n' >"$live_config"
IPKG_INSTROOT="" "$script_path"
assert_file_contains "$live_config" "new-config" "postinst should restore changed config backup"
[[ ! -e "$backup_path" ]] || fail "postinst should consume changed config backup"

# apk runs default_postinst ("/etc/init.d/mihowrt start") before this hook:
# preinst makes that start a no-op, postinst decides and clears the marker.
rm -f "$skip_start"
IPKG_INSTROOT="" "$preinst_path"
[[ -e "$skip_start" ]] || fail "preinst should skip the default postinst start"
IPKG_INSTROOT="" "$script_path"
[[ ! -e "$skip_start" ]] || fail "postinst should clear the skip marker"

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
assert_file_contains "$hook_log" "mihowrt:recover" "prerm should clean runtime state before package files are removed"
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
assert_eq '["read"]' "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/always_proxy_dst.txt"]' "$acl_file")" "ACL should allow reading destination policy list"
assert_eq '["read"]' "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/always_proxy_src.txt"]' "$acl_file")" "ACL should allow reading source policy list"
assert_eq '["read"]' "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/direct_dst.txt"]' "$acl_file")" "ACL should allow reading direct destination list"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/lst/always_proxy_dst.txt"] // null' "$acl_file")" "ACL should not allow direct destination policy list writes from LuCI"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/lst/always_proxy_src.txt"] // null' "$acl_file")" "ACL should not allow direct source policy list writes from LuCI"
assert_eq "null" "$(jq -c '."luci-app-mihowrt".write.file["/opt/clash/lst/direct_dst.txt"] // null' "$acl_file")" "ACL should not allow direct policy list writes from LuCI"
assert_eq '["write"]' "$(jq -c '."luci-app-mihowrt".write.file["/tmp/mihowrt-policy-list.*"]' "$acl_file")" "ACL should allow only temp policy list staging from LuCI"

assert_file_contains "$ROOT_DIR/Makefile" "\$(1)/lib/upgrade/keep.d" "package should install sysupgrade keep directory"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/usr/bin/mihowrt-read' "package should install read-only backend wrapper"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/lib/upgrade/keep.d/mihowrt' "package should install MihoWRT sysupgrade keep list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/view/mihowrt/*' "package should install LuCI view assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/www/luci-static/resources/mihowrt/*' "package should install LuCI helper assets on upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -f /tmp/luci-indexcache' "postinst should clear LuCI index cache after upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -rf /tmp/luci-modulecache' "postinst should clear LuCI module cache after upgrade"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -rf /opt/clash/ruleset' "package removal should remove ruleset directory safely"
assert_file_contains "$ROOT_DIR/Makefile" 'rm -rf /opt/clash/proxy_providers' "package removal should remove proxy provider directory safely"
assert_file_not_contains "$ROOT_DIR/Makefile" 'rm -f /opt/clash/ruleset' "package removal should not use file-only removal for ruleset directory"
assert_file_not_contains "$ROOT_DIR/Makefile" 'rm -f /opt/clash/proxy_providers' "package removal should not use file-only removal for proxy provider directory"
assert_file_contains "$ROOT_DIR/Makefile" '/opt/clash/lst/direct_dst.txt' "package conffiles should include direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/clash/lst/direct_dst.txt' "package should install direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_mihowrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/clash/config.yaml || exit 1' "postinst should fail if saved config cannot be restored"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/direct_dst.txt /opt/clash/lst/direct_dst.txt || exit 1' "postinst should fail if saved policy lists cannot be restored"
assert_file_contains "$ROOT_DIR/Makefile" '/opt/clash/mihomo.sock' "package removal should delete Mihomo socket symlink"
assert_file_contains "$ROOT_DIR/Makefile" '# mihowrt subscription auto-update' "package removal should delete subscription cron entry"
assert_file_contains "$ROOT_DIR/Makefile" '# mihowrt policy remote auto-update' "package removal should delete policy remote cron entry"
assert_file_contains "$ROOT_DIR/Makefile" '+curl' "package should depend on curl for Mihomo API hot reload"
installer_deps="$(sed -n 's/^DEPS="\(.*\)"$/\1/p' "$ROOT_DIR/install.sh")"
for dep in $installer_deps; do
	assert_file_contains "$ROOT_DIR/Makefile" "+$dep" "installer dependency $dep must match package LUCI_DEPENDS"
done
assert_file_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "option subscription_url ''" "default UCI config should disable subscriptions"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "policy_remote_update_interval" "default UCI config should use per-URL policy list intervals"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "route_table_id" "default UCI config should keep route table selection automatic"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/config/mihowrt" "route_rule_priority" "default UCI config should keep route rule selection automatic"
assert_file_contains "$keep_file" "/etc/config/mihowrt" "sysupgrade keep list should preserve UCI config"
assert_file_contains "$keep_file" "/etc/mihowrt" "sysupgrade keep list should preserve persistent MihoWRT state"
assert_file_contains "$keep_file" "/opt/clash/config.yaml" "sysupgrade keep list should preserve Mihomo config"
assert_file_contains "$keep_file" "/opt/clash/lst" "sysupgrade keep list should preserve policy lists"
assert_file_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/mihowrt.list" "/opt/clash/lst/direct_dst.txt" "APK protected paths should preserve direct destination list"
assert_file_not_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/mihowrt.list" "/www/luci-static" "APK protected paths should not preserve stale LuCI assets"

pass "package hook snippets"

source_init_mihowrt_lib
SKIP_START_FILE="$skip_start"
MIHOWRT="$tmpdir/mihowrt"
procd_open_instance() { printf 'procd:open\n' >>"$hook_log"; }
procd_set_param() { :; }
procd_close_instance() { :; }
: >"$skip_start"
: >"$hook_log"
start_service
[[ ! -e "$skip_start" ]] || fail "start_service should consume the skip marker"
assert_file_not_contains "$hook_log" "mihowrt:prepare" "skipped start should not prepare"
: >"$skip_start"
touch -d '2024-01-01 00:00:00' "$skip_start"
start_service
assert_file_contains "$hook_log" "mihowrt:prepare" "a stale marker (failed install) must not block Start"
[[ ! -e "$skip_start" ]] || fail "stale marker removed"
: >"$hook_log"
assert_file_not_contains "$hook_log" "mihowrt:prepare" "skipped start should not prepare"
start_service
assert_file_contains "$hook_log" "mihowrt:prepare" "next start should run normally"
assert_file_contains "$hook_log" "procd:open" "next start should launch the service"
pass "default postinst start skipped once"

assert_eq '["read"]' "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/direct_src.txt"]' "$acl_file")" "fourth list read ACL"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/clash/lst/direct_src.txt' "fourth list packaged"
