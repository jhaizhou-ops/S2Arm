# native-test-nvn_cpsfail：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_cpsfail
ifeq ($(shell uname -s),Darwin)
# 计算管线建失败只建一次（怪猎崛起线程组内存超限，原先每次派发重编，真机 45 秒不出帧）
$(BUILD)/tests/t_nvn_cpsfail: graphics/nvn/tests/t_nvn_cpsfail.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_cpsfail.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_cpsfail
native-test-nvn_cpsfail: $(BUILD)/tests/t_nvn_cpsfail
	$(BUILD)/tests/t_nvn_cpsfail
TEST_TARGETS += native-test-nvn_cpsfail
endif
