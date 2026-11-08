# native-test-nvn_img_ubo：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_img_ubo
ifeq ($(shell uname -s),Darwin)
# 句柄在统一缓冲里的存储图像（img_ubo，无人深空 11-05）
$(BUILD)/tests/t_nvn_img_ubo: graphics/nvn/tests/t_nvn_img_ubo.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_img_ubo.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_img_ubo
native-test-nvn_img_ubo: $(BUILD)/tests/t_nvn_img_ubo
	$(BUILD)/tests/t_nvn_img_ubo
TEST_TARGETS += native-test-nvn_img_ubo
endif
