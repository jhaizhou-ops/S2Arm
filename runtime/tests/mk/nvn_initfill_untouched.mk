# native-test-nvn_initfill_untouched：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_initfill_untouched
ifeq ($(shell uname -s),Darwin)
# 贴图初始内容判全 0 不读游戏没碰过的页（11-05 时之笛 iPhone：新建 GPU 贴图的存储被整段读一遍，未写页进足迹）
$(BUILD)/tests/t_nvn_initfill_untouched: graphics/nvn/tests/t_nvn_initfill_untouched.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_initfill_untouched.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_initfill_untouched
native-test-nvn_initfill_untouched: $(BUILD)/tests/t_nvn_initfill_untouched
	$(BUILD)/tests/t_nvn_initfill_untouched
TEST_TARGETS += native-test-nvn_initfill_untouched
endif
