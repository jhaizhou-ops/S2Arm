# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 通用上下分屏：生产几何 / 设置的 Mac 单测，以及 UIKit 接线的 iOS SDK 类型检查。
NATIVE_TEST_OWN += play_layout
.PHONY: native-test-play_layout
native-test-play_layout:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_play_layout runtime/tests/t_play_layout.m ios/play_layout.m
	$(BUILD)/tests/t_play_layout
ifeq ($(shell uname -s),Darwin)
	@$(IOS_CC) -fsyntax-only -fobjc-arc $(NATIVE_INC) -Iruntime/src -Iruntime/ns2pro/include ios/play_layout.m ios/app.m ios/vpad.m ios/app_settings.m ios/save_transfer.m
endif
TEST_TARGETS += native-test-play_layout
