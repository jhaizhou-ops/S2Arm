# native-test-nvn_warm_fb：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_warm_fb
ifeq ($(shell uname -s),Darwin)
# 本机现编过的着色器进预热与预取（七龙珠 电光炸裂 ZERO 11-06）
NVN_WARM_FB_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
$(BUILD)/tests/t_nvn_warm_fb: graphics/nvn/tests/t_nvn_warm_fb.m $(NVN_WARM_FB_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DNVN_WARM_FB_SOURCE='"$(abspath $(NVN_WARM_FB_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_warm_fb.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_warm_fb
native-test-nvn_warm_fb: $(BUILD)/tests/t_nvn_warm_fb
	$(BUILD)/tests/t_nvn_warm_fb
TEST_TARGETS += native-test-nvn_warm_fb
endif
