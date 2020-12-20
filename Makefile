export THEOS_DEVICE_IP=192.168.86.10

ARCHS = arm64
TARGET=iphone:clang:13.5.1:13.5.1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = carplayenable
carplayenable_FILES = $(wildcard hooks/*.xm) $(wildcard *.mm)

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard CarPlay"

test::
	install.exec "cycript -p SpringBoard" < tests/springboard_tests.cy
	install.exec "cycript -p CarPlay" < tests/carplay_tests.cy