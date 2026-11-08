# native-test-nvn_argenc：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_argenc
ifeq ($(shell uname -s),Darwin)
# 参数块长度按反射算、不再问 Metal（nvn_mtl.m shader_args_init）：模拟编译服务失效（函数无参数块、反射说有）不崩，反证子进程问 Metal 必 SIGABRT
$(BUILD)/tests/t_nvn_argenc: graphics/nvn/tests/t_nvn_argenc.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_argenc.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_argenc
native-test-nvn_argenc: $(BUILD)/tests/t_nvn_argenc
	$(BUILD)/tests/t_nvn_argenc && NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_argenc
TEST_TARGETS += native-test-nvn_argenc
endif
