export THEOS_DEVICE_IP=192.168.86.5

ARCHS = arm64
TARGET=iphone:clang:13.5:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = carplayenable
carplayenable_FILES = $(wildcard *.xm)

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard CarPlay"
