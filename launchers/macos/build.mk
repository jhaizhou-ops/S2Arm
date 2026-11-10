# Mac game window/input shell; launcher preparation opts in with a private BUILD.
ifeq ($(S2A_MAC_FRONTEND),1)
CFLAGS += -fobjc-arc
# 玩家入口：自动玩家缺省关（tests/autoplay/ap_default.h）
CFLAGS += -DS2A_MAC_FRONTEND=1
HOST_SRCS += macos/front_mac.m macos/input_guide.m macos/controller_view.m macos/textinput_mac.m
HOST_LIBS += -framework AppKit -framework CoreGraphics -framework GameController -framework CoreHaptics
$(BUILD)/s2arm-host: launchers/macos/build.mk
endif
