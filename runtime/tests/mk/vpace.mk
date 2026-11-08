# native-test-vpace：视频按片源帧率出图的判定（graphics/nvn/gfx/nvn/nvn_vpace.h，纯 C，不要 GPU）
NATIVE_TEST_OWN += vpace
.PHONY: native-test-vpace
native-test-vpace:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_vpace graphics/nvn/tests/t_vpace.c
	timeout 30 $(BUILD)/tests/t_vpace
	@echo '✓ t_vpace：视频按片源帧率出图的判定全过'
TEST_TARGETS += native-test-vpace
