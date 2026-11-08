# native-test-nvn_wdusage：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_wdusage
ifeq ($(shell uname -s),Darwin)
# 直连宽屏：存储放不宽的渲染目标不按放宽登记给核心（巫师3 直连标志视频左侧品红，10-26）
$(BUILD)/tests/t_nvn_wdusage: graphics/nvn/tests/t_nvn_wdusage.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_wdusage.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_wdusage
native-test-nvn_wdusage: $(BUILD)/tests/t_nvn_wdusage
	$(BUILD)/tests/t_nvn_wdusage
TEST_TARGETS += native-test-nvn_wdusage
endif
