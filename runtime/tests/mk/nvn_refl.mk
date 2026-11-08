# native-test-nvn_refl：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_refl
ifeq ($(shell uname -s),Darwin)
# 反射绑定数组按个数分配（怪猎 71 个、暗黑2 68 个绑定的着色器原先被固定 64 拒载）
$(BUILD)/tests/t_nvn_refl: graphics/nvn/tests/t_nvn_refl.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_refl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_refl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_refl
native-test-nvn_refl: $(BUILD)/tests/t_nvn_refl
	$(BUILD)/tests/t_nvn_refl
TEST_TARGETS += native-test-nvn_refl
endif
