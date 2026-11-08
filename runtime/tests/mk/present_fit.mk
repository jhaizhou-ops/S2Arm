# native-test-present_fit：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 直连上屏裁剪规整 + 等比视口（graphics/nvn/gfx/nvn/nvn_present_fit.h，纯 C，不要 GPU）：10-28 斯普拉遁3 直连满屏开局裁剪比交换链宽
NATIVE_TEST_OWN += present_fit
.PHONY: native-test-present_fit
native-test-present_fit:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_present_fit graphics/nvn/tests/t_present_fit.c -lm
	timeout 30 $(BUILD)/tests/t_present_fit
TEST_TARGETS += native-test-present_fit
