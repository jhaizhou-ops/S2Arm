# native-test-nvn_fb_pin：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_fb_pin
ifeq ($(shell uname -s),Darwin)
# 同遍反馈采样：采样器钉住一级的绘制读那一级的单级视图（fb_pinned_level，上游参考实现（MIT）56e4577b）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_fb_pin: graphics/nvn/tests/t_nvn_fb_pin.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_fb_pin.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_fb_pin
native-test-nvn_fb_pin: $(BUILD)/tests/t_nvn_fb_pin
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_fb_pin
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_fb_pin
TEST_TARGETS += native-test-nvn_fb_pin
endif
