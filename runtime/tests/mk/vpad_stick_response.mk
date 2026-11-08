# 摇杆手感：Foundation 层公式与持久化回归（Mac 可跑）。
NATIVE_TEST_OWN += vpad_stick_response
.PHONY: native-test-vpad_stick_response
native-test-vpad_stick_response:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_stick_response runtime/tests/t_vpad_stick_response.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_stick_response
TEST_TARGETS += native-test-vpad_stick_response
