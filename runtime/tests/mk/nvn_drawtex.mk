# native-test-nvn_drawtex：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_drawtex
ifeq ($(shell uname -s),Darwin)
# DrawTexture（nvn_mtl.m draw_tex，10-30 Bare Knuckle IV）：真 Metal 设备回放，读回目标逐像素按手算比（1:1 / x 反向 / 放大 2 倍），并核画完后游戏状态原样
$(BUILD)/tests/t_nvn_drawtex: graphics/nvn/tests/t_nvn_drawtex.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_drawtex.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_drawtex
native-test-nvn_drawtex: $(BUILD)/tests/t_nvn_drawtex
	$(BUILD)/tests/t_nvn_drawtex && NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_drawtex
TEST_TARGETS += native-test-nvn_drawtex
endif
