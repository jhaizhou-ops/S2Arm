# native-test-nvn_be：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_be
# 直连回放层选路 Metal 4 / Metal 3（graphics/nvn/gfx/nvn/nvn_be.h，#277）：纯 C，不需要 GPU 或游戏。
.PHONY: native-test-nvn_be
native-test-nvn_be:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_nvn_be graphics/nvn/tests/t_nvn_be.c
	timeout 30 $(BUILD)/tests/t_nvn_be
TEST_TARGETS += native-test-nvn_be
