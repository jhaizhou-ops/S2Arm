# native-test-nvn_unnorm：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_unnorm
ifeq ($(shell uname -s),Darwin)
# #968 第 1 步 iOS 宿主：每次绘制按有效目标给支持缓冲 s2a_flags.yzw 填非归一化坐标位（nvn_unnorm.inc）
$(BUILD)/tests/t_nvn_unnorm: graphics/nvn/tests/t_nvn_unnorm.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_unnorm.inc graphics/nvn/gfx/nvn/nvn_size_abi.inc graphics/nvn/gfx/nvn/nvn_refl.h graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_unnorm.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_unnorm
native-test-nvn_unnorm: $(BUILD)/tests/t_nvn_unnorm
	$(BUILD)/tests/t_nvn_unnorm
TEST_TARGETS += native-test-nvn_unnorm
endif
