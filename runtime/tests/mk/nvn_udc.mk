# 未写附件不写回在 TBDR 组关时也生效（graphics/nvn/tests/t_nvn_udc.m）。
NATIVE_TEST_OWN += nvn_udc
ifeq ($(shell uname -s),Darwin)
NVN_UDC_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_UDC_BINARY ?= $(BUILD)/tests/t_nvn_udc
$(NVN_UDC_BINARY): graphics/nvn/tests/t_nvn_udc.m $(NVN_UDC_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -I$(abspath $(NVN_TEST_DIR)/nvn/gen) -DNVN_UDC_SOURCE='"$(abspath $(NVN_UDC_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_udc.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_udc
native-test-nvn_udc: $(NVN_UDC_BINARY)
	$(NVN_UDC_BINARY)
TEST_TARGETS += native-test-nvn_udc
endif
