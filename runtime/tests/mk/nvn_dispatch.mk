# native-test-nvn_dispatch：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_dispatch
ifeq ($(shell uname -s),Darwin)
# 间接计算派发从 c0 读组数（#329 第 2 类，#374）：生产宿主 / NVN 库真跑 Metal 4 / 3 × 共用 / 独立编码器四路，GPU 读回逐线程记录
$(BUILD)/tests/t_nvn_dispatch: graphics/nvn/tests/t_nvn_dispatch.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_dispatch.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_dispatch
native-test-nvn_dispatch: $(BUILD)/tests/t_nvn_dispatch
	$(BUILD)/tests/t_nvn_dispatch
TEST_TARGETS += native-test-nvn_dispatch
endif
