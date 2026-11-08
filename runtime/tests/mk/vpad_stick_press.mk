# native-test-vpad_stick_press：虚拟手柄摇杆按下 LS / RS（ios/vpad_layout.m 默认布局 + 按点取键 + 点按判定，Foundation 层，Mac 上编）
NATIVE_TEST_OWN += vpad_stick_press
.PHONY: native-test-vpad_stick_press
native-test-vpad_stick_press:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_stick_press runtime/tests/t_vpad_stick_press.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_stick_press
TEST_TARGETS += native-test-vpad_stick_press
