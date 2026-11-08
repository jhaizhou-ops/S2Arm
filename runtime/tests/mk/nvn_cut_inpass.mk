# native-test-nvn_cut_inpass：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_cut_inpass
ifeq ($(shell uname -s),Darwin)
# 遍内切段：GPU 没活时在两笔绘制之间提交（11-07 时之笛 GPU 空等）
$(BUILD)/tests/t_nvn_cut_inpass: graphics/nvn/tests/t_nvn_cut_inpass.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_cut_inpass.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_cut_inpass
native-test-nvn_cut_inpass: $(BUILD)/tests/t_nvn_cut_inpass
	$(BUILD)/tests/t_nvn_cut_inpass
TEST_TARGETS += native-test-nvn_cut_inpass
endif
