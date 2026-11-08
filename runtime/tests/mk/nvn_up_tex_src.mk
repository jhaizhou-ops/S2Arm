# native-test-nvn_up_tex_src：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_up_tex_src
ifeq ($(shell uname -s),Darwin)
# 只放贴图的池上传贴图时不进常驻集合（up_tex_src，时之笛 iOS GPU 常驻超上限）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_up_tex_src: graphics/nvn/tests/t_nvn_up_tex_src.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_up_tex_src.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_up_tex_src
native-test-nvn_up_tex_src: $(BUILD)/tests/t_nvn_up_tex_src
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_up_tex_src
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_up_tex_src
TEST_TARGETS += native-test-nvn_up_tex_src
endif
