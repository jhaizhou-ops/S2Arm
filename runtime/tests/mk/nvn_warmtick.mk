# native-test-nvn_warmtick：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_warmtick
ifeq ($(shell uname -s),Darwin)
# 加载页节拍（warm_prepare ↔ 前端 s2a_front_warm_tick）：前端返回 1 转后台、返回 0 等全部编完；开始 (0, N) 与编完 (N, N) 各一次
# 宿主目标里的 runtime/src/loadprog.c（加载页前端，真机线 runtime/load-page）给的是正式的 s2a_front_warm_tick：本单测换成替身，链接时把它去掉
NVN_WARMTICK_HOST_OBJS = $(filter-out %/loadprog.c.o,$(NVN_TEST_HOST_OBJS))
$(BUILD)/tests/t_nvn_warmtick: graphics/nvn/tests/t_nvn_warmtick.m $(NVN_MTL_DEPS) $(NVN_WARMTICK_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_warmtick.m graphics/nvn/tests/warmtick_front_stub.c $(NVN_WARMTICK_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_warmtick
native-test-nvn_warmtick: $(BUILD)/tests/t_nvn_warmtick
	$(BUILD)/tests/t_nvn_warmtick
TEST_TARGETS += native-test-nvn_warmtick
endif
