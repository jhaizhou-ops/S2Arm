# native-test-nvn_wdresolve：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_wdresolve
ifeq ($(shell uname -s),Darwin)
# 直连宽屏：放宽过的多重采样目标解析（Downsample）到同尺寸单样本贴图，目标随源放宽、整张解析（10-30 Fit Boxing / 哆啦A梦 / 植物大战僵尸）；窄屏加高的源拷进普通贴图按存储高换算 y（11-02 丝之歌重影）
$(BUILD)/tests/t_nvn_wdresolve: graphics/nvn/tests/t_nvn_wdresolve.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_wdresolve.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_wdresolve
native-test-nvn_wdresolve: $(BUILD)/tests/t_nvn_wdresolve
	$(BUILD)/tests/t_nvn_wdresolve
TEST_TARGETS += native-test-nvn_wdresolve
endif
