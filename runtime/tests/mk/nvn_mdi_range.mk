# native-test-nvn_mdi_range：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_mdi_range
ifeq ($(shell uname -s),Darwin)
# 间接计数多绘超过 1,024 条整段一条记录、回放按 GPU 掩码分批（draw_multi，上游参考实现（MIT）c7ba23df）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_mdi_range: graphics/nvn/tests/t_nvn_mdi_range.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn2_cmd.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_mdi_range.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_mdi_range
native-test-nvn_mdi_range: $(BUILD)/tests/t_nvn_mdi_range
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_mdi_range
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_mdi_range
TEST_TARGETS += native-test-nvn_mdi_range
endif
