# native-test-nvn_sdx_cold：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_sdx_cold
ifeq ($(shell uname -s),Darwin)
# 存储前瞻不装冷键（审计 #1534 P1-111）：TBDR 开着时提交开头的前瞻只用已装好的程序，冷键程序不在前瞻里解析 / 现编；Metal 4 / Metal 3 两路
$(BUILD)/tests/t_nvn_sdx_cold: graphics/nvn/tests/t_nvn_sdx_cold.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_sdx_cold.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_sdx_cold
native-test-nvn_sdx_cold: $(BUILD)/tests/t_nvn_sdx_cold
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_sdx_cold
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_sdx_cold
TEST_TARGETS += native-test-nvn_sdx_cold
endif
