# 遮挡查询槽表折叠（11-05 王国之泪约 3.3 万帧后 visibility slot list 分配失败）：生产 nvn_mtl.m + 真 Metal 缓冲，graphics/nvn/tests/t_nvn_visfold.m
NATIVE_TEST_OWN += nvn_visfold
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_visfold: graphics/nvn/tests/t_nvn_visfold.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_visfold.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_visfold
native-test-nvn_visfold: $(BUILD)/tests/t_nvn_visfold
	$(BUILD)/tests/t_nvn_visfold
TEST_TARGETS += native-test-nvn_visfold
endif
