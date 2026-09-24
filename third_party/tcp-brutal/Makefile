include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=tcp-brutal
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/HyNetworks/tcp-brutal.git
PKG_SOURCE_VERSION:=6733b75aa3aaf59f832d3eed27d608dab4c7fdc1
PKG_SOURCE_DATE:=2026-09-11
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NNdroid

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/kernel-defaults.mk

define KernelPackage/brutal
  SECTION:=kernel
  SUBMENU:=Network Support
  TITLE:=TCP Brutal v2 congestion control
  FILES:=$(PKG_BUILD_DIR)/brutal.$(LINUX_KMOD_SUFFIX)
  AUTOLOAD:=$(call AutoLoad,30,brutal)
endef

define KernelPackage/brutal/description
  Hysteria's Brutal congestion control algorithm as a Linux TCP module.
  Brutal v2 supports destination-prefix rules and shared bandwidth groups.
endef

define Package/brutalctl
  SECTION:=net
  CATEGORY:=Network
  TITLE:=TCP Brutal v2 rule manager
  DEPENDS:=+kmod-brutal +ip-full
endef

define Package/brutalctl/description
  Manage TCP Brutal destination rules and the iproute2 routes that select
  the Brutal congestion-control algorithm.
endef

define Build/Configure
endef

define Build/Compile
	$(KERNEL_MAKE) M="$(PKG_BUILD_DIR)" modules
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-o $(PKG_BUILD_DIR)/tools/brutalctl \
		$(PKG_BUILD_DIR)/tools/brutalctl.c \
		$(TARGET_LDFLAGS)
endef

define Package/brutalctl/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/tools/brutalctl $(1)/usr/bin/brutalctl
endef

$(eval $(call KernelPackage,brutal))
$(eval $(call BuildPackage,brutalctl))
