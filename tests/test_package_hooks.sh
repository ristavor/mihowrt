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
was_running_marker="$tmpdir/was-running"
acl_file="$ROOT_DIR/rootfs/usr/share/rpcd/acl.d/luci-app-mihowrt.json"
keep_file="$ROOT_DIR/rootfs/lib/upgrade/keep.d/mihowrt"

assert_file_contains "$ROOT_DIR/Makefile" 'MIHOWRT_LISTS:=always_proxy_dst always_proxy_src direct_dst direct_src' "list names should have one Makefile definition"
render_package_define conffiles >"$tmpdir/conffiles"
if grep -q '^$' "$tmpdir/conffiles"; then
	fail "conffiles should not contain empty lines"
fi
render_package_define preinst >"$tmpdir/preinst.expanded"
render_package_define postinst >"$tmpdir/postinst.expanded"
for list in always_proxy_dst always_proxy_src direct_dst direct_src; do
	grep -Fxq "/opt/clash/lst/$list.txt" "$tmpdir/conffiles" || fail "conffiles should preserve $list on its own exact line"
	assert_file_contains "$ROOT_DIR/rootfs/etc/apk/protected_paths.d/mihowrt.list" "/opt/clash/lst/$list.txt" "APK should preserve $list"
done
assert_file_contains "$tmpdir/preinst.expanded" 'for list in always_proxy_dst always_proxy_src direct_dst direct_src' "preinst should back up all list files"
assert_file_contains "$tmpdir/postinst.expanded" 'for list in always_proxy_dst always_proxy_src direct_dst direct_src' "postinst should restore all list files"
assert_file_contains "$keep_file" '/opt/clash/lst' "sysupgrade should preserve list directory"
assert_file_contains "$tmpdir/postinst.expanded" '. /usr/lib/mihowrt/constants.sh' "postinst should source constants"
assert_file_contains "$tmpdir/postinst.expanded" 'pgrep -f "$SUPERVISOR_CMD"' "postinst should use supervisor constant"
pass "list files consistent and postinst constants sourced"

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
		-e "s|/tmp/luci-app-mihowrt.config.yaml.bak|$backup_path|g" \
		-e "s|/tmp/luci-app-mihowrt.policy-lists.bak|$list_backup_dir|g" \
		-e "s|/opt/clash/config.yaml|$live_config|g" \
		-e "s|/opt/clash/lst|$live_list_dir|g"
}

extract_preinst() {
	render_package_define preinst |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-mihowrt.skip-start|$skip_start|g" \
			-e "s|/tmp/luci-app-mihowrt.was-running|$was_running_marker|g"
}

extract_postinst() {
	render_package_define postinst |
		rewrite_package_paths |
		sed \
			-e "s|/tmp/luci-app-mihowrt.skip-start|$skip_start|g" \
			-e "s|/tmp/luci-app-mihowrt.was-running|$was_running_marker|g" \
			-e "s|/usr/lib/mihowrt/constants.sh|$MIHOWRT_LIB_DIR/constants.sh|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g" \
			-e "s|/etc/init.d/mihowrt |$tmpdir/init-mihowrt |g" \
			-e 's|/etc/init.d/mihowrt-recover enable >/dev/null 2>&1|true|g' \
			-e 's|/etc/init.d/rpcd reload|true|g'
}

extract_prerm() {
	render_package_define prerm |
		sed \
			-e "s|/etc/init.d/mihowrt-recover|$tmpdir/init-recover|g" \
			-e "s|/etc/init.d/mihowrt|$tmpdir/init-mihowrt|g" \
			-e "s|/usr/bin/mihowrt|$tmpdir/mihowrt|g"
}

mkdir -p "$(dirname "$live_config")" "$live_list_dir"

extract_hook "preinst" >"$tmpdir/preinst.raw"
assert_file_contains "$tmpdir/preinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)' "preinst should stage policy list backups before package payload install"
assert_file_contains "$tmpdir/preinst.raw" "backup_mihowrt_file" "preinst should use fail-fast backup helper"
assert_file_contains "$tmpdir/preinst.raw" '/opt/clash/lst/$$list.txt' "preinst should back up policy list paths from its loop"
extract_hook "postinst" >"$tmpdir/postinst.raw"
assert_file_contains "$tmpdir/postinst.raw" "/tmp/luci-app-mihowrt.skip-start" "postinst should clear the skip marker"
assert_file_contains "$tmpdir/postinst.raw" '$(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt' "postinst should restore policy list backups from its loop"
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

mkdir -p "$tmpdir/bin"
cat >"$tmpdir/bin/pgrep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat >"$tmpdir/init-mihowrt" <<EOF
#!/bin/sh
printf 'init:%s\n' "\$*" >>"$hook_log"
EOF
chmod +x "$tmpdir/bin/pgrep" "$tmpdir/init-mihowrt"
: >"$hook_log"
set +e
PATH="$tmpdir/bin:$PATH" TEST_FAIL_MIGRATE=1 IPKG_INSTROOT="" "$script_path"
postinst_migrate_fail_rc=$?
set -e
[[ "$postinst_migrate_fail_rc" -eq 1 ]] || fail "postinst should fail when package migration fails"
assert_file_contains "$hook_log" "mihowrt:migrate" "postinst should attempt package migration before failing"

assert_file_contains "$hook_log" "init:stop" "running service stopped before migration"
assert_file_contains "$hook_log" "init:start" "service restarted despite migration failure"
assert_eq "$(printf 'init:stop\nmihowrt:migrate\ninit:start')" "$(cat "$hook_log")" "postinst failure restart order"
pass "postinst migrate failure restarts service"

# default_postinst stops the service (skipped start_service) before our
# postinst runs, so the running state is recorded by preinst.
mkdir -p "$tmpdir/bin-running" "$tmpdir/bin-stopped"
printf '#!/bin/sh\nexit 0\n' >"$tmpdir/bin-running/pgrep"
printf '#!/bin/sh\nexit 1\n' >"$tmpdir/bin-stopped/pgrep"
chmod +x "$tmpdir/bin-running/pgrep" "$tmpdir/bin-stopped/pgrep"

rm -f "$was_running_marker"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$preinst_path"
[[ ! -e "$was_running_marker" ]] || fail "preinst should not mark a stopped service as running"
PATH="$tmpdir/bin-running:$PATH" IPKG_INSTROOT="" "$preinst_path"
[[ -e "$was_running_marker" ]] || fail "preinst should record a running supervisor"

: >"$hook_log"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$script_path"
assert_file_contains "$hook_log" "init:start" "marker restarts a service stopped by default_postinst"
[[ ! -e "$was_running_marker" ]] || fail "postinst should remove the was-running marker"

: >"$hook_log"
PATH="$tmpdir/bin-stopped:$PATH" IPKG_INSTROOT="" "$script_path"
assert_file_not_contains "$hook_log" "init:" "no marker and no supervisor must not start the service"

: >"$was_running_marker"
: >"$hook_log"
set +e
PATH="$tmpdir/bin-stopped:$PATH" TEST_FAIL_MIGRATE=1 IPKG_INSTROOT="" "$script_path"
marker_fail_rc=$?
set -e
assert_eq 1 "$marker_fail_rc" "migrate failure with marker still exits 1"
assert_file_contains "$hook_log" "init:start" "migrate failure with marker still starts the service"
[[ ! -e "$was_running_marker" ]] || fail "marker removed after failed migrate"
pass "was-running marker keeps service running across upgrade"

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
assert_file_contains "$hook_log" "mihowrt:uninstall" "prerm runs uninstall before package files are removed"
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
assert_eq null "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/always_proxy_dst.txt"]' "$acl_file")" "ACL should not directly read destination policy list"
assert_eq null "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/always_proxy_src.txt"]' "$acl_file")" "ACL should not directly read source policy list"
assert_eq null "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/direct_dst.txt"]' "$acl_file")" "ACL should not directly read direct destination list"
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
assert_file_contains "$tmpdir/conffiles" '/opt/clash/lst/direct_dst.txt' "package conffiles should include direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/clash/lst/$$$$list.txt' "package should install direct destination list"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_mihowrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/clash/config.yaml || exit 1' "postinst should fail if saved config cannot be restored"
assert_file_contains "$ROOT_DIR/Makefile" 'restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt /opt/clash/lst/$$list.txt || exit 1' "postinst should fail if saved policy lists cannot be restored"
render_package_define postrm >"$tmpdir/postrm.expanded"
for forbidden in cron dnsmasq sed /etc/init.d/mihowrt; do
	assert_file_not_contains "$tmpdir/postrm.expanded" "$forbidden" "postrm has no runtime logic: $forbidden"
done
for leftover in /tmp/mihowrt /var/run/mihowrt /tmp/clash; do
	assert_file_contains "$tmpdir/postrm.expanded" "$leftover" "postrm removes $leftover"
done
postrm_root="$tmpdir/postrm-root"
mkdir -p "$postrm_root/tmp/mihowrt" "$postrm_root/var/run/mihowrt" "$postrm_root/tmp/clash"
sed -e "s|/tmp/|@ROOT@/tmp/|g" -e "s|/var/run/|@ROOT@/var/run/|g" \
	-e "s|/opt/|@ROOT@/opt/|g" -e "s|/etc/|@ROOT@/etc/|g" \
	-e "s|@ROOT@|$postrm_root|g" "$tmpdir/postrm.expanded" >"$tmpdir/postrm.sh"
IPKG_INSTROOT="$tmpdir/image" ash "$tmpdir/postrm.sh"
[[ -d "$postrm_root/tmp/clash" ]] || fail "postrm skips image builds"
IPKG_INSTROOT="" ash "$tmpdir/postrm.sh"
for leftover in tmp/mihowrt var/run/mihowrt tmp/clash; do
	[[ ! -e "$postrm_root/$leftover" ]] || fail "postrm removes $leftover"
done
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

assert_eq null "$(jq -c '."luci-app-mihowrt".read.file["/opt/clash/lst/direct_src.txt"]' "$acl_file")" "fourth list read ACL"
assert_file_contains "$ROOT_DIR/Makefile" './rootfs/opt/clash/lst/$$$$list.txt' "fourth list packaged"
assert_file_not_contains "$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/traffic.js" LIST_FILES 'traffic uses lists-json, not direct files'
assert_file_contains "$ROOT_DIR/rootfs/www/luci-static/resources/view/mihowrt/traffic.js" "api.readLarge('lists-json')" 'traffic reads large JSON through CGI helper'

# Exercise the actual CLI/modules in ash, with all system paths in a fixture.
uninstall_root="$tmpdir/uninstall"
mkdir -p "$uninstall_root/lib" "$uninstall_root/opt/clash/bin" "$uninstall_root/opt/clash/ui" \
	"$uninstall_root/opt/clash/lst" "$uninstall_root/etc/mihowrt/policy-cache" \
	"$uninstall_root/etc/config" "$uninstall_root/etc/init.d" "$uninstall_root/tmp/dnsmasq.test.d" \
	"$uninstall_root/tmp/clash/ruleset" "$uninstall_root/tmp/clash/proxy_providers" \
	"$uninstall_root/var/run/mihowrt" "$uninstall_root/tmp/mihowrt" "$uninstall_root/etc/crontabs"
for module in "$MIHOWRT_LIB_DIR"/*.sh; do
	sed -e "s|/opt/clash|@ROOT@/opt/clash|g" \
		-e "s|/etc/|@ROOT@/etc/|g" \
		-e "s|/tmp/|@ROOT@/tmp/|g" \
		-e "s|/var/run/mihowrt|@ROOT@/var/run/mihowrt|g" \
		-e "s|@ROOT@|$uninstall_root|g" \
		"$module" >"$uninstall_root/lib/${module##*/}"
done
# Recovery still uses real dns_cleanup; nft/routes have no host effects.
cat >>"$uninstall_root/lib/service.sh" <<'EOF'
service_pid() { return 1; }
nft_cleanup() { :; }
route_cleanup() { :; }
EOF
cat >"$uninstall_root/etc/init.d/mihowrt" <<EOF
#!/bin/ash
[ ! -e /proc/self/fd/9 ] || exit 1
printf 'init:%s\n' "\$*" >>"$uninstall_root/actions"
EOF
for daemon in cron dnsmasq; do
	printf '#!/bin/ash\necho "%s:$*" >>"%s/actions"\n' "$daemon" "$uninstall_root" >"$uninstall_root/etc/init.d/$daemon"
done
chmod +x "$uninstall_root/etc/init.d/"*
for removed in bin/clash ui/index.html GeoIP.dat GeoSite.dat geoip.dat geosite.dat geoip.metadb Country.mmdb country.mmdb GeoLite2-ASN.mmdb ASN.mmdb; do
	touch "$uninstall_root/opt/clash/$removed"
done
for removed in subscription.json cache.db policy-cache/x dns.backup; do
	touch "$uninstall_root/etc/mihowrt/$removed"
done
for kept in opt/clash/config.yaml opt/clash/config.yaml.bak opt/clash/lst/custom.txt opt/clash/manual.txt etc/config/mihowrt etc/mihowrt/hwid; do
	printf 'keep\n' >"$uninstall_root/$kept"
done
for name in ruleset proxy_providers cache.db mihomo.sock; do
	touch "$uninstall_root/tmp/clash/$name/fixture" 2>/dev/null || touch "$uninstall_root/tmp/clash/$name"
	ln -s "$uninstall_root/tmp/clash/$name" "$uninstall_root/opt/clash/$name"
done
printf '0 * * * * user-job\n0 * * * * /usr/bin/mihowrt auto-update # mihowrt auto-update\n' >"$uninstall_root/etc/crontabs/root"
touch "$uninstall_root/tmp/dnsmasq.test.d/mihowrt.conf"
sed "s|/etc/init.d/mihowrt|$uninstall_root/etc/init.d/mihowrt|g" "$ROOT_DIR/rootfs/usr/bin/mihowrt" >"$uninstall_root/cli"
MIHOWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall
assert_eq 'init:stop' "$(head -n 1 "$uninstall_root/actions")" "uninstall stops first, outside runtime lock"
for removed in bin/clash ui GeoIP.dat GeoSite.dat geoip.dat geosite.dat geoip.metadb Country.mmdb country.mmdb GeoLite2-ASN.mmdb ASN.mmdb ruleset proxy_providers cache.db mihomo.sock; do
	[[ ! -e "$uninstall_root/opt/clash/$removed" && ! -L "$uninstall_root/opt/clash/$removed" ]] || fail "uninstall removes $removed"
done
for removed in etc/mihowrt/subscription.json etc/mihowrt/cache.db etc/mihowrt/policy-cache etc/mihowrt/dns.backup tmp/mihowrt var/run/mihowrt tmp/clash tmp/dnsmasq.test.d/mihowrt.conf; do
	[[ ! -e "$uninstall_root/$removed" ]] || fail "uninstall removes $removed"
done
for kept in opt/clash/config.yaml opt/clash/config.yaml.bak opt/clash/lst/custom.txt opt/clash/manual.txt etc/config/mihowrt etc/mihowrt/hwid; do
	assert_file_contains "$uninstall_root/$kept" keep "uninstall keeps $kept"
done
assert_eq '0 * * * * user-job' "$(cat "$uninstall_root/etc/crontabs/root")" "uninstall keeps unrelated cron jobs"
assert_eq 1 "$(grep -c '^cron:restart$' "$uninstall_root/actions")" "uninstall restarts cron once"
assert_eq 1 "$(grep -c '^dnsmasq:restart$' "$uninstall_root/actions")" "uninstall restores DNS once"
pass "uninstall removes generated assets and keeps user files"

# A lingering supervisor must not leave the router pointing at a deleted core.
# Keep markers outside removed directories to prove their explicit removal.
cat >>"$uninstall_root/lib/service.sh" <<'EOF_STUBS'
pgrep() { return 0; }
RUNNING_MARKER="$CLASH_DIR/test-running"
SERVICE_PID_FILE="$CLASH_DIR/test-pid"
dns_cleanup() { [ -e /proc/self/fd/9 ] || return 1; echo dns >>"$CLASH_DIR/cleanup-calls"; }
nft_cleanup() { echo nft >>"$CLASH_DIR/cleanup-calls"; }
route_cleanup() { echo route >>"$CLASH_DIR/cleanup-calls"; }
EOF_STUBS
touch "$uninstall_root/opt/clash/test-running" "$uninstall_root/opt/clash/test-pid"
MIHOWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall
assert_eq $'dns\nnft\nroute' "$(cat "$uninstall_root/opt/clash/cleanup-calls" 2>/dev/null || true)" "lingering supervisor still restores DNS/nft/routes under lock"
for marker in test-running test-pid; do
	[[ ! -e "$uninstall_root/opt/clash/$marker" ]] || fail "uninstall explicitly removes $marker"
done
pass "uninstall restores router state despite lingering supervisor"

cat >>"$uninstall_root/lib/service.sh" <<'EOF_STUBS'
cron_sync() { return 1; }
EOF_STUBS
touch "$uninstall_root/opt/clash/bin/clash" "$uninstall_root/opt/clash/GeoIP.dat"
rc=0
MIHOWRT_LIB_DIR="$uninstall_root/lib" ash "$uninstall_root/cli" uninstall || rc=$?
assert_eq 1 "$rc" "uninstall reports cron cleanup failure"
[[ ! -e "$uninstall_root/opt/clash/bin/clash" ]] || fail "cron failure must not skip core deletion"
[[ ! -e "$uninstall_root/opt/clash/GeoIP.dat" ]] || fail "cron failure must not skip geodata deletion"
pass "uninstall continues deletions after cron failure"
