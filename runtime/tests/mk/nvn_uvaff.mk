# native-test-nvn_uvaff：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_uvaff
ifeq ($(shell uname -s),Darwin)
# 着色器事实里的常量引用覆盖整 64 KB 常量缓冲（上游参考实现（MIT）d6a2808a）
$(BUILD)/tests/t_nvn_uvaff: graphics/nvn/tests/t_nvn_uvaff.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_uvaff.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_uvaff
native-test-nvn_uvaff: $(BUILD)/tests/t_nvn_uvaff
	$(BUILD)/tests/t_nvn_uvaff
TEST_TARGETS += native-test-nvn_uvaff
endif
