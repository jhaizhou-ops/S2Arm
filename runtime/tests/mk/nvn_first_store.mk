# native-test-nvn_first_store：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_first_store
ifeq ($(shell uname -s),Darwin)
# 只有第一个调用写的存储由宿主派发前写（first_store，上游参考实现（MIT）c8521eeb / e07cba1c 宿主半边）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_first_store: graphics/nvn/tests/t_nvn_first_store.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_first_store.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_first_store
native-test-nvn_first_store: $(BUILD)/tests/t_nvn_first_store
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_first_store
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_first_store
TEST_TARGETS += native-test-nvn_first_store
endif
