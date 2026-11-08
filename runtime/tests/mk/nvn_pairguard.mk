# native-test-nvn_pairguard：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pairguard
ifeq ($(shell uname -s),Darwin)
# 顶点 / 片元配对核对（pso_pair_ok）：不匹配的对不交给 Metal、记 P 行（iOS 上建这种管线 Metal 断言崩溃，巫师3 10-26）
$(BUILD)/tests/t_nvn_pairguard: graphics/nvn/tests/t_nvn_pairguard.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pairguard.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pairguard
native-test-nvn_pairguard: $(BUILD)/tests/t_nvn_pairguard
	$(BUILD)/tests/t_nvn_pairguard
TEST_TARGETS += native-test-nvn_pairguard
endif
