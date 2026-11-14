# OpenWrt package for LobbyFence (place this directory in a package feed)
# SPDX-License-Identifier: GPL-3.0-or-later

include $(TOPDIR)/rules.mk

PKG_NAME:=lobbyfence
PKG_VERSION:=1.3.7
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=Femto-Gurifisu

include $(INCLUDE_DIR)/package.mk

define Package/lobbyfence
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  TITLE:=Geographic game-server filter (nftables)
  DEPENDS:=+nftables +kmod-nft-core
  PKGARCH:=all
endef

define Package/lobbyfence/description
  Learns which servers a game on your network connects to, locates them,
  and can block servers outside the regions (circles or countries) you allow.
endef

define Package/lobbyfence/conffiles
/etc/config/lobbyfence
/etc/lobbyfence/
endef

define Build/Compile
endef

define Package/lobbyfence/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/usr/sbin $(1)/usr/share/lobbyfence
	$(INSTALL_CONF) ./files/etc/config/lobbyfence $(1)/etc/config/lobbyfence
	$(INSTALL_BIN) ./files/etc/init.d/lobbyfence $(1)/etc/init.d/lobbyfence
	$(INSTALL_BIN) ./files/usr/sbin/lobbyfence $(1)/usr/sbin/lobbyfence
	$(INSTALL_DATA) ./files/usr/share/lobbyfence/lobbyfence.awk $(1)/usr/share/lobbyfence/lobbyfence.awk
	$(INSTALL_DATA) ./files/usr/share/lobbyfence/fw-nft.sh $(1)/usr/share/lobbyfence/fw-nft.sh
	$(INSTALL_DATA) ./files/usr/share/lobbyfence/servers.txt $(1)/usr/share/lobbyfence/servers.txt
	$(INSTALL_DATA) ./files/usr/share/lobbyfence/server-networks.txt $(1)/usr/share/lobbyfence/server-networks.txt
	$(INSTALL_DATA) ./files/usr/share/lobbyfence/share-games.txt $(1)/usr/share/lobbyfence/share-games.txt
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/lobbyfence $(1)/lib/upgrade/keep.d/lobbyfence
endef

define Package/lobbyfence/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/lobbyfence stop
exit 0
endef

$(eval $(call BuildPackage,lobbyfence))
