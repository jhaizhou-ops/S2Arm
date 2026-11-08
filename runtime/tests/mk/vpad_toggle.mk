# native-test-vpad_toggle：「键 / 触」一键切换（ios/vpad_layout.m，Foundation 层，Mac 上编）
NATIVE_TEST_OWN += vpad_toggle
.PHONY: native-test-vpad_toggle
native-test-vpad_toggle:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_toggle runtime/tests/t_vpad_toggle.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_toggle
TEST_TARGETS += native-test-vpad_toggle
