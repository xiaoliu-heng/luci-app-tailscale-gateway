include $(TOPDIR)/rules.mk

LUCI_TITLE:=Tailscale Gateway
LUCI_DEPENDS:=+tailscale-gateway +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all
PKG_VERSION:=0.2.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
