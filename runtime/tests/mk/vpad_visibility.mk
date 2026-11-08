# C01-3: production visibility targets and preference persistence on Mac.
NATIVE_TEST_OWN += vpad_visibility
.PHONY: native-test-vpad_visibility
native-test-vpad_visibility:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -framework Foundation -framework CoreGraphics -o $(BUILD)/tests/t_vpad_visibility runtime/tests/t_vpad_visibility.m ios/vpad_layout.m
	$(BUILD)/tests/t_vpad_visibility
TEST_TARGETS += native-test-vpad_visibility
