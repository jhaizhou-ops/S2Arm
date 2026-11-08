# native-test-nvn_texfit_l0：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_texfit_l0
ifeq ($(shell uname -s),Darwin)
# tex_fit 兼容视图的起点（mip 级 / 层）：带偏移的视图 + 维度不匹配时，视图必须从 parentRelativeLevel / parentRelativeSlice 起算
$(BUILD)/tests/t_nvn_texfit_l0: graphics/nvn/tests/t_nvn_texfit_l0.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_texfit_l0.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_texfit_l0
native-test-nvn_texfit_l0: $(BUILD)/tests/t_nvn_texfit_l0
	$(BUILD)/tests/t_nvn_texfit_l0
TEST_TARGETS += native-test-nvn_texfit_l0
endif
