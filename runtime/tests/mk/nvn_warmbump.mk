# native-test-nvn_warmbump：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_warmbump
ifeq ($(shell uname -s),Darwin)
# 预热插队（warm_bump / warm_pick）：游戏登记程序时把清单里这对着色器的管线提到队头，不重复领
NVN_WARMBUMP_HOST_OBJS = $(filter-out %/loadprog.c.o,$(NVN_TEST_HOST_OBJS))   # 同 nvn_warmtick：前端换替身
$(BUILD)/tests/t_nvn_warmbump: graphics/nvn/tests/t_nvn_warmbump.m $(NVN_MTL_DEPS) $(NVN_WARMBUMP_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_warmbump.m graphics/nvn/tests/warmtick_front_stub.c $(NVN_WARMBUMP_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_warmbump
native-test-nvn_warmbump: $(BUILD)/tests/t_nvn_warmbump
	$(BUILD)/tests/t_nvn_warmbump
TEST_TARGETS += native-test-nvn_warmbump
endif
