# Copyright 2026

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mihowrt
PKG_VERSION:=0.2.5
PKG_RELEASE:=1
PKG_MAINTAINER:=maintainer
PKG_CONFIG_BACKUP_FILE:=/tmp/$(PKG_NAME).config.yaml.bak

LUCI_TITLE:=LuCI Support for MihoWRT
LUCI_DEPENDS:=+luci-base +jq +nftables +kmod-nft-tproxy
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
	LuCI interface and direct-first nft policy layer for MihoWRT on OpenWrt 25.12 APK systems.
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

ifdef CONFIG_USE_APK
	$(INSTALL_DIR) $(1)/etc/apk/protected_paths.d
	$(INSTALL_DATA) ./rootfs/etc/apk/protected_paths.d/mihowrt.list $(1)/etc/apk/protected_paths.d/
endif
endef

define Package/$(PKG_NAME)/preinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	rm -f $(PKG_CONFIG_BACKUP_FILE)
	[ -f /opt/clash/config.yaml ] && cp -p /opt/clash/config.yaml $(PKG_CONFIG_BACKUP_FILE)
}
exit 0
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	if [ -f $(PKG_CONFIG_BACKUP_FILE) ]; then
		mv $(PKG_CONFIG_BACKUP_FILE) /opt/clash/config.yaml
	fi
	sync_tmp_link() {
		src="$$1"
		dst="$$2"
		mkdir -p "$$dst"
		if [ -d "$$src" ] && [ ! -L "$$src" ]; then
			cp -a "$$src"/. "$$dst"/ 2>/dev/null || true
		fi
		if [ ! -L "$$src" ] || [ "$$(readlink "$$src" 2>/dev/null)" != "$$dst" ]; then
			rm -rf "$$src"
			ln -s "$$dst" "$$src"
		fi
	}
	sync_tmp_file() {
		src="$$1"
		dst="$$2"
		mkdir -p "$$(dirname "$$dst")"
		if [ -f "$$src" ] && [ ! -L "$$src" ]; then
			cp -a "$$src" "$$dst" 2>/dev/null || true
		fi
		if [ ! -L "$$src" ] || [ "$$(readlink "$$src" 2>/dev/null)" != "$$dst" ]; then
			rm -rf "$$src"
			ln -s "$$dst" "$$src"
		fi
	}
	mkdir -p /opt/clash/lst
	sync_tmp_link /opt/clash/ruleset /tmp/clash/ruleset
	sync_tmp_link /opt/clash/proxy_providers /tmp/clash/proxy_providers
	sync_tmp_file /opt/clash/cache.db /tmp/clash/cache.db
	[ -f /opt/clash/lst/always_proxy_dst.txt ] || touch /opt/clash/lst/always_proxy_dst.txt
	[ -f /opt/clash/lst/always_proxy_src.txt ] || touch /opt/clash/lst/always_proxy_src.txt
	/etc/init.d/mihowrt-recover enable >/dev/null 2>&1 || true
	/etc/init.d/rpcd reload
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
}
exit 0
endef

define Package/$(PKG_NAME)/postrm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
	/etc/init.d/mihowrt stop >/dev/null 2>&1 || true
	rm -f /etc/apk/protected_paths.d/mihowrt.list
	rm -f /opt/clash/ruleset
	rm -f /opt/clash/proxy_providers
	rm -f /opt/clash/cache.db
	rm -rf /tmp/clash/ruleset
	rm -rf /tmp/clash/proxy_providers
	rm -f /tmp/clash/cache.db
	rmdir /tmp/clash 2>/dev/null || true
	rm -rf /tmp/mihowrt
	rm -rf /var/run/mihowrt
	rm -f /etc/mihowrt/dns.backup
	rmdir /etc/mihowrt 2>/dev/null || true
	rm -rf /www/luci-static/resources/view/mihowrt
	rm -rf /www/luci-static/resources/mihowrt
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
