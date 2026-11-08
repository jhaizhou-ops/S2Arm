# native-test-nvn_pso_lookahead：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pso_lookahead
ifeq ($(shell uname -s),Darwin)
# 首遇管线并行预编：第一次缺管线先往前看、把本提交后面的管线踢到后台再等（93dc5957e 起没跑，派对 11-02 一帧 61 条串行 1.8 秒）；后台表满回收编完没人取的
$(BUILD)/tests/t_nvn_pso_lookahead: graphics/nvn/tests/t_nvn_pso_lookahead.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pso_lookahead.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pso_lookahead
native-test-nvn_pso_lookahead: $(BUILD)/tests/t_nvn_pso_lookahead
	$(BUILD)/tests/t_nvn_pso_lookahead
TEST_TARGETS += native-test-nvn_pso_lookahead
endif
