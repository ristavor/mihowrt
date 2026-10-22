# Copyright 2026

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mihowrt
PKG_VERSION:=0.10.0
PKG_RELEASE:=1
PKG_MAINTAINER:=ristavor <90447432+ristavor@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_CONFIG_BACKUP_FILE:=/tmp/$(PKG_NAME).config.yaml.bak
PKG_POLICY_LIST_BACKUP_DIR:=/tmp/$(PKG_NAME).policy-lists.bak
MIHOWRT_LISTS:=always_proxy_dst always_proxy_src direct_dst direct_src

LUCI_TITLE:=LuCI Support for MihoWRT
LUCI_DEPENDS:=+luci-base +cgi-io +jq +nftables +kmod-nft-tproxy +curl
LUCI_PKGARCH:=all

PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=$(LUCI_TITLE)
	DEPENDS:=$(LUCI_DEPENDS)
	PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/$(PKG_NAME)/description
	LuCI interface and nft policy layer for MihoWRT on OpenWrt 25.12 APK systems.
endef

define Build/Prepare
endef

define Build/Compile
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	po2lmo ./po/ru/mihowrt.po $(PKG_BUILD_DIR)/mihowrt.ru.lmo
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/mihowrt
/opt/clash/config.yaml
$(subst $(space),$(newline),$(addprefix /opt/clash/lst/,$(addsuffix .txt,$(MIHOWRT_LISTS))))
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/mihowrt $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/mihowrt-recover $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./rootfs/etc/config/mihowrt $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./rootfs/etc/hotplug.d/iface/90-mihowrt $(1)/etc/hotplug.d/iface/

	$(INSTALL_DIR) $(1)/etc/mihowrt

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./rootfs/usr/bin/mihowrt $(1)/usr/bin/
	$(INSTALL_BIN) ./rootfs/usr/bin/mihowrt-read $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/lib/mihowrt
	$(CP) ./rootfs/usr/lib/mihowrt/* $(1)/usr/lib/mihowrt/
	sed -i 's/^PKG_VERSION=.*/PKG_VERSION="$(PKG_VERSION)"/' $(1)/usr/lib/mihowrt/constants.sh

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./rootfs/usr/share/luci/menu.d/luci-app-mihowrt.json $(1)/usr/share/luci/menu.d/

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./rootfs/usr/share/rpcd/acl.d/luci-app-mihowrt.json $(1)/usr/share/rpcd/acl.d/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/mihowrt
	$(CP) ./rootfs/www/luci-static/resources/view/mihowrt/* $(1)/www/luci-static/resources/view/mihowrt/

	$(INSTALL_DIR) $(1)/www/luci-static/resources/mihowrt
	$(CP) ./rootfs/www/luci-static/resources/mihowrt/* $(1)/www/luci-static/resources/mihowrt/

	$(INSTALL_DIR) $(1)/opt/clash/bin
	$(INSTALL_DIR) $(1)/opt/clash/lst
	$(INSTALL_DATA) ./rootfs/opt/clash/config.yaml $(1)/opt/clash/
	for list in $(MIHOWRT_LISTS); do \
		$(INSTALL_DATA) ./rootfs/opt/clash/lst/$$$$list.txt $(1)/opt/clash/lst/ || exit 1; \
	done

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./rootfs/lib/upgrade/keep.d/mihowrt $(1)/lib/upgrade/keep.d/

ifdef CONFIG_USE_APK
	$(INSTALL_DIR) $(1)/etc/apk/protected_paths.d
	$(INSTALL_DATA) ./rootfs/etc/apk/protected_paths.d/mihowrt.list $(1)/etc/apk/protected_paths.d/
endif
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	# default_postinst may stop the service (skipped start below), so
	# record the running state now; the new constants.sh is not installed yet.
	rm -f /tmp/luci-app-mihowrt.was-running
	if pgrep -f "/usr/bin/mihowrt run-service" >/dev/null 2>&1; then
		: >/tmp/luci-app-mihowrt.was-running
	fi
	backup_mihowrt_file() {
		src="$$1"
		backup_file="$$2"
		[ -f "$$src" ] || return 0
		mkdir -p "$${backup_file%/*}" || return 1
		cp -p "$$src" "$$backup_file" || return 1
	}
	# apk runs default_postinst, which calls "/etc/init.d/mihowrt start",
	# before our postinst: skip that start, postinst decides.
	: >/tmp/luci-app-mihowrt.skip-start
	rm -f $(PKG_CONFIG_BACKUP_FILE) || exit 1
	rm -rf $(PKG_POLICY_LIST_BACKUP_DIR) || exit 1
	backup_mihowrt_file /opt/clash/config.yaml $(PKG_CONFIG_BACKUP_FILE) || exit 1
	for list in $(MIHOWRT_LISTS); do
		backup_mihowrt_file /opt/clash/lst/$$list.txt $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt || exit 1
	done
}
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	. /usr/lib/mihowrt/constants.sh
	restore_mihowrt_backup_file() {
		backup_file="$$1"
		target_file="$$2"
		[ -f "$$backup_file" ] || return 0
		if [ ! -f "$$target_file" ] || ! cmp -s "$$backup_file" "$$target_file"; then
			mkdir -p "$${target_file%/*}" 2>/dev/null || return 1
			mv "$$backup_file" "$$target_file" || return 1
		else
			rm -f "$$backup_file" || return 1
		fi
	}
	restore_mihowrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/clash/config.yaml || exit 1
	for list in $(MIHOWRT_LISTS); do
		restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/$$list.txt /opt/clash/lst/$$list.txt || exit 1
	done
	rmdir $(PKG_POLICY_LIST_BACKUP_DIR) 2>/dev/null || true
	rm -f /tmp/luci-app-mihowrt.skip-start
	# An upgrade leaves the old service running from memory: stop it so
	# it removes its own state, migrate, then start the new version.
	rc=0
	was_running=0
	[ -e /tmp/luci-app-mihowrt.was-running ] && was_running=1
	pgrep -f "$$SUPERVISOR_CMD" >/dev/null 2>&1 && was_running=1
	rm -f /tmp/luci-app-mihowrt.was-running
	[ "$$was_running" = 1 ] && /etc/init.d/mihowrt stop >/dev/null 2>&1
	[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt migrate >/dev/null 2>&1 || rc=1
	[ "$$was_running" = 1 ] && /etc/init.d/mihowrt start >/dev/null 2>&1
	/etc/init.d/mihowrt-recover enable >/dev/null 2>&1 || true
	/etc/init.d/rpcd reload
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	exit $$rc
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt uninstall >/dev/null 2>&1 || true
	/etc/init.d/mihowrt-recover disable >/dev/null 2>&1 || true
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	rm -rf /tmp/mihowrt /var/run/mihowrt /tmp/clash
	rmdir /opt/clash/bin /opt/clash /etc/mihowrt 2>/dev/null || true
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

define Package/luci-i18n-mihowrt-ru
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=$(PKG_NAME) - Russian translation
	DEPENDS:=$(PKG_NAME)
	PKGARCH:=all
endef

define Package/luci-i18n-mihowrt-ru/description
	Russian translation for $(PKG_NAME).
endef

define Package/luci-i18n-mihowrt-ru/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/mihowrt.ru.lmo $(1)/usr/lib/lua/luci/i18n/
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	( \
		echo '#!/bin/sh'; \
		echo 'uci -q get luci.languages.ru >/dev/null || {'; \
		echo '	uci set luci.languages.ru='\''русский (Russian)'\'';'; \
		echo '	uci commit luci'; \
		echo '}'; \
		echo 'exit 0'; \
	) > $(1)/etc/uci-defaults/luci-i18n-mihowrt-ru
	chmod 0755 $(1)/etc/uci-defaults/luci-i18n-mihowrt-ru
endef

define Package/luci-i18n-mihowrt-ru/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	uci -q get luci.languages.ru >/dev/null || {
		uci set luci.languages.ru='русский (Russian)'
		uci commit luci
	}
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

$(eval $(call BuildPackage,luci-i18n-mihowrt-ru))

