include $(TOPDIR)/rules.mk

PKG_NAME:=tailscale-gateway
PKG_VERSION:=0.2.0
PKG_RELEASE:=2
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/tailscale-gateway
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Tailscale gateway policies and DNS synchronization
  DEPENDS:=+tailscale +ip-full +firewall4 +busybox +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +ucode-mod-digest +jsonfilter
  PKGARCH:=all
endef

define Package/tailscale-gateway/conffiles
/etc/config/tailscale_gateway
endef

define Build/Compile
endef

define Package/tailscale-gateway/install
	$(CP) ./files/* $(1)/
endef

define Package/tailscale-gateway/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || {
  /etc/init.d/tailscale-gateway enable
  /etc/init.d/tailscale-gateway start
}
exit 0
endef

define Package/tailscale-gateway/prerm
#!/bin/sh
if [ -z "$$IPKG_INSTROOT" ]; then
  if ! /usr/libexec/tailscale-gateway check-uninstall; then
    umask 077
    tar -czf /etc/tailscale-gateway/uninstall-recovery.tar.gz /usr/share/tailscale-gateway /usr/libexec/tailscale-gateway* /etc/init.d/tailscale-gateway /etc/config/tailscale_gateway
    echo 'Managed UCI/DNS rules are retained. Reinstall to revert adoption.' >&2
  fi
  /etc/init.d/tailscale-gateway stop
  /etc/init.d/tailscale-gateway disable
fi
exit 0
endef

$(eval $(call BuildPackage,tailscale-gateway))
