# native-test-nvn_smg3_stall：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_smg3_stall
ifeq ($(shell uname -s),Darwin)
# 斯普拉遁3 停帧（10-26）：立方体读作立方体数组的视图、后台管线有界等待
$(BUILD)/tests/t_nvn_smg3_stall: graphics/nvn/tests/t_nvn_smg3_stall.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_smg3_stall.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_smg3_stall
native-test-nvn_smg3_stall: $(BUILD)/tests/t_nvn_smg3_stall
	$(BUILD)/tests/t_nvn_smg3_stall
TEST_TARGETS += native-test-nvn_smg3_stall
endif
