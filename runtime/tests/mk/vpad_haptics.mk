# C01-1：触屏反馈触发与设置持久化（Foundation 主机测试）。
NATIVE_TEST_OWN += vpad_haptics
.PHONY: native-test-vpad_haptics
native-test-vpad_haptics:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_haptics runtime/tests/t_vpad_haptics.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_haptics
TEST_TARGETS += native-test-vpad_haptics
