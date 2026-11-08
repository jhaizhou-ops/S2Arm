# native-test-nvn_gpu_halt：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_gpu_halt
ifeq ($(shell uname -s),Darwin)
# GPU 挂死安全停（11-07 测试机2 金刚挂死后照常提交、整机卡死）：判定 + 停后各提交入口不交
$(BUILD)/tests/t_nvn_gpu_halt: graphics/nvn/tests/t_nvn_gpu_halt.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_gpu_halt.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_gpu_halt
native-test-nvn_gpu_halt: $(BUILD)/tests/t_nvn_gpu_halt
	$(BUILD)/tests/t_nvn_gpu_halt
TEST_TARGETS += native-test-nvn_gpu_halt
endif
