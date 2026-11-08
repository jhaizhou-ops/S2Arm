# native-test-vk_lbias：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# Vulkan 层采样器 LOD 偏置改写（graphics/nvn/gfx/vk/vk_lbias.inc，#800）逐字核 + 改写结果 xcrun metal 编过；GPU 读数在 tests/vk_core ⑭
NATIVE_TEST_OWN += vk_lbias
.PHONY: native-test-vk_lbias
native-test-vk_lbias:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_vk_lbias graphics/nvn/tests/t_vk_lbias.c
	timeout 60 $(BUILD)/tests/t_vk_lbias
TEST_TARGETS += native-test-vk_lbias
