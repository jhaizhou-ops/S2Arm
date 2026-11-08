# native-test-nvn_tbdr_ubd：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tbdr_ubd
ifeq ($(shell uname -s),Darwin)
# TBDR 开着时遍内常量更新延后 / 惰性清除仍开（审计 #1508 T7）：直接包含生产 nvn_mtl.m；缺省一遍、两开关显式关一遍
$(BUILD)/tests/t_nvn_tbdr_ubd: graphics/nvn/tests/t_nvn_tbdr_ubd.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tbdr_ubd.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tbdr_ubd
native-test-nvn_tbdr_ubd: $(BUILD)/tests/t_nvn_tbdr_ubd
	DM_NVN_TBDR=1 $(BUILD)/tests/t_nvn_tbdr_ubd on
	DM_NVN_TBDR=1 DM_NVN_UB_DEFER=0 DM_NVN_LAZY_CLEAR=0 $(BUILD)/tests/t_nvn_tbdr_ubd off
TEST_TARGETS += native-test-nvn_tbdr_ubd
endif
