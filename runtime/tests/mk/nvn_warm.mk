# native-test-nvn_warm：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 管线预热进度纯逻辑（graphics/nvn/gfx/nvn/nvn_warm.h，纯 C，不要 GPU）：加载页何时交还宿主、速率滑动窗口
NATIVE_TEST_OWN += nvn_warm
.PHONY: native-test-nvn_warm
native-test-nvn_warm:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_nvn_warm -Igraphics/nvn/gfx/nvn graphics/nvn/tests/t_nvn_warm.c -lm
	timeout 30 $(BUILD)/tests/t_nvn_warm
TEST_TARGETS += native-test-nvn_warm
