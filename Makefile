# Copyright 2026

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mihowrt
PKG_VERSION:=0.7.4
PKG_RELEASE:=1
PKG_MAINTAINER:=maintainer
PKG_CONFIG_BACKUP_FILE:=/tmp/$(PKG_NAME).config.yaml.bak
PKG_POLICY_LIST_BACKUP_DIR:=/tmp/$(PKG_NAME).policy-lists.bak

LUCI_TITLE:=LuCI Support for MihoWRT
LUCI_DEPENDS:=+luci-base +jq +nftables +kmod-nft-tproxy +@wget-any +curl
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
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/mihowrt
/opt/clash/config.yaml
/opt/clash/lst/always_proxy_dst.txt
/opt/clash/lst/always_proxy_src.txt
/opt/clash/lst/direct_dst.txt
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./rootfs/etc/init.d/mihowrt $(1)/etc/init.d/
	$(INSTALL_BIN) ./rootfs/etc/init.d/mihowrt-recover $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./rootfs/etc/config/mihowrt $(1)/etc/config/

	$(INSTALL_DIR) $(1)/etc/mihowrt

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./rootfs/usr/bin/mihowrt $(1)/usr/bin/
	$(INSTALL_BIN) ./rootfs/usr/bin/mihowrt-read $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/usr/lib/mihowrt
	$(CP) ./rootfs/usr/lib/mihowrt/* $(1)/usr/lib/mihowrt/

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
	$(INSTALL_DATA) ./rootfs/opt/clash/lst/always_proxy_dst.txt $(1)/opt/clash/lst/
	$(INSTALL_DATA) ./rootfs/opt/clash/lst/always_proxy_src.txt $(1)/opt/clash/lst/
	$(INSTALL_DATA) ./rootfs/opt/clash/lst/direct_dst.txt $(1)/opt/clash/lst/

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
	rm -f $(PKG_CONFIG_BACKUP_FILE)
	rm -rf $(PKG_POLICY_LIST_BACKUP_DIR)
	[ -f /opt/clash/config.yaml ] && cp -p /opt/clash/config.yaml $(PKG_CONFIG_BACKUP_FILE)
	mkdir -p $(PKG_POLICY_LIST_BACKUP_DIR)
	[ -f /opt/clash/lst/always_proxy_dst.txt ] && cp -p /opt/clash/lst/always_proxy_dst.txt $(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_dst.txt
	[ -f /opt/clash/lst/always_proxy_src.txt ] && cp -p /opt/clash/lst/always_proxy_src.txt $(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_src.txt
	[ -f /opt/clash/lst/direct_dst.txt ] && cp -p /opt/clash/lst/direct_dst.txt $(PKG_POLICY_LIST_BACKUP_DIR)/direct_dst.txt
}
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	restore_mihowrt_backup_file() {
		backup_file="$$1"
		target_file="$$2"
		[ -f "$$backup_file" ] || return 0
		if [ ! -f "$$target_file" ] || ! cmp -s "$$backup_file" "$$target_file"; then
			mkdir -p "$${target_file%/*}" 2>/dev/null || true
			mv "$$backup_file" "$$target_file"
		else
			rm -f "$$backup_file"
		fi
	}
	restore_mihowrt_backup_file $(PKG_CONFIG_BACKUP_FILE) /opt/clash/config.yaml
	restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_dst.txt /opt/clash/lst/always_proxy_dst.txt
	restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/always_proxy_src.txt /opt/clash/lst/always_proxy_src.txt
	restore_mihowrt_backup_file $(PKG_POLICY_LIST_BACKUP_DIR)/direct_dst.txt /opt/clash/lst/direct_dst.txt
	rmdir $(PKG_POLICY_LIST_BACKUP_DIR) 2>/dev/null || true
	if [ ! -f /tmp/luci-app-mihowrt.skip-start ]; then
		[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt migrate-legacy-settings >/dev/null 2>&1 || true
		[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt migrate-policy-lists >/dev/null 2>&1 || true
	fi
	[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt init-layout >/dev/null 2>&1 || true
	/etc/init.d/mihowrt-recover enable >/dev/null 2>&1 || true
	/etc/init.d/rpcd reload
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/mihowrt stop >/dev/null 2>&1 || true
	[ -x /usr/bin/mihowrt ] && /usr/bin/mihowrt cleanup >/dev/null 2>&1 || true
	/etc/init.d/mihowrt-recover disable >/dev/null 2>&1 || true
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/mihowrt stop >/dev/null 2>&1 || true
	rm -f /etc/apk/protected_paths.d/mihowrt.list
	sed -i '/# mihowrt subscription auto-update/d' /etc/crontabs/root 2>/dev/null || true
	sed -i '/# mihowrt policy remote auto-update/d' /etc/crontabs/root 2>/dev/null || true
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	rm -f /opt/clash/ruleset
	rm -f /opt/clash/proxy_providers
	rm -f /opt/clash/cache.db
	rm -f /opt/clash/mihomo.sock
	rm -rf /tmp/clash/ruleset
	rm -rf /tmp/clash/proxy_providers
	rm -f /tmp/clash/cache.db
	rm -f /tmp/clash/mihomo.sock
	rmdir /tmp/clash 2>/dev/null || true
	rm -rf /tmp/mihowrt
	rm -rf /var/run/mihowrt
	rm -f /etc/mihowrt/dns.backup
	rm -rf /etc/mihowrt/policy-cache
	rmdir /etc/mihowrt 2>/dev/null || true
	rm -rf /www/luci-static/resources/view/mihowrt
	rm -rf /www/luci-static/resources/mihowrt
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
