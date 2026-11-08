# native-test-nvn_rgba_atomic：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rgba_atomic
ifeq ($(shell uname -s),Darwin)
# RGBA8 纹理当 R32 整数原子图像：R32 存储 + 同字节 RGBA8 视图（缺口 #8）
$(BUILD)/tests/t_nvn_rgba_atomic: graphics/nvn/tests/t_nvn_rgba_atomic.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_rgba_atomic.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rgba_atomic
native-test-nvn_rgba_atomic: $(BUILD)/tests/t_nvn_rgba_atomic
	$(BUILD)/tests/t_nvn_rgba_atomic
TEST_TARGETS += native-test-nvn_rgba_atomic
endif
