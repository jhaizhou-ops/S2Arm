# 按游戏自定义按键位置：布局按游戏目录存、外观按 App 存，拖动编辑生成的方案覆盖保存（vpad_layout.m）；
#   Mac 上另用 iOS SDK 对 vpad.m / vpad_settings.m 做语法与类型检查（编辑模式、描线配色都在 vpad.m，Foundation 单测编不到）
NATIVE_TEST_OWN += vpad_custom
.PHONY: native-test-vpad_custom
native-test-vpad_custom:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_custom runtime/tests/t_vpad_custom.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_custom
ifeq ($(shell uname -s),Darwin)
	@$(IOS_CC) -fsyntax-only -fobjc-arc $(NATIVE_INC) -Iruntime/src -Iruntime/ns2pro/include ios/vpad.m ios/vpad_settings.m ios/vpad_shell.m ios/settings.m
endif
TEST_TARGETS += native-test-vpad_custom

# 游戏库调整按键位置的宿主接口（vpad_shell.m，s2a_shell_vpad_*）
NATIVE_TEST_OWN += vpad_shell
.PHONY: native-test-vpad_shell
native-test-vpad_shell:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_shell runtime/tests/t_vpad_shell.m ios/vpad_shell.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_shell
TEST_TARGETS += native-test-vpad_shell
