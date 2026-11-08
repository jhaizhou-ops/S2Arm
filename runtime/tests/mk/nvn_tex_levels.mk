# mip 层数按尺寸夹（11-05 朋友收集 128×256 要 15 层，Metal 断言 abort）：生产 nvn_mtl.m + 真 Metal 设备，graphics/nvn/tests/t_nvn_tex_levels.m
NATIVE_TEST_OWN += nvn_tex_levels
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_tex_levels: graphics/nvn/tests/t_nvn_tex_levels.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tex_levels.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tex_levels
native-test-nvn_tex_levels: $(BUILD)/tests/t_nvn_tex_levels
	$(BUILD)/tests/t_nvn_tex_levels
TEST_TARGETS += native-test-nvn_tex_levels
endif
