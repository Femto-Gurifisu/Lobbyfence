# LuCI app for LobbyFence
# SPDX-License-Identifier: GPL-3.0-or-later

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for LobbyFence (geographic game-server filter)
LUCI_DEPENDS:=+luci-base +lobbyfence
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=Femto-Gurifisu

# inside the LuCI tree use: include ../../luci.mk
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
