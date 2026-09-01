THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WatusiJetsamUncap
WatusiJetsamUncap_FILES = Tweak.x
WatusiJetsamUncap_CFLAGS = -fobjc-arc
WatusiJetsamUncap_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
