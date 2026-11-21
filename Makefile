TARGET = iphone:clang:16.5:3.0
ARCHS = armv7

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RedGIFsCompat
RedGIFsCompat_FILES = Tweak.xm
RedGIFsCompat_FRAMEWORKS = Foundation
RedGIFsCompat_CFLAGS = -fno-objc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
