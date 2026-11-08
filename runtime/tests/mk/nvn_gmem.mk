# native-test-nvn_gmem：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_gmem
ifeq ($(shell uname -s),Darwin)
# 原始全局内存池表（gmem_map / gmem_log：只收给过地址的池、按 GPU 地址窗口建表、提示字、写记录位图；时之笛 11-06）
$(BUILD)/tests/t_nvn_gmem: graphics/nvn/tests/t_nvn_gmem.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_gmem.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_gmem
native-test-nvn_gmem: $(BUILD)/tests/t_nvn_gmem
	$(BUILD)/tests/t_nvn_gmem
TEST_TARGETS += native-test-nvn_gmem
endif
