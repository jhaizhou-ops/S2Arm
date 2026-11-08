# 缺口族 43：RGBX 顶点格式并到同宽 RGB（生产 state_op + pso_desc，真 Metal 设备读回）。反证：NVN_VFMT_SOURCE=<旧 nvn_mtl.m>
NATIVE_TEST_OWN += nvn_vfmt_rgbx
ifeq ($(shell uname -s),Darwin)
NVN_VFMT_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_VFMT_BINARY ?= $(BUILD)/tests/t_nvn_vfmt_rgbx
$(NVN_VFMT_BINARY): graphics/nvn/tests/t_nvn_vfmt_rgbx.m $(NVN_VFMT_SOURCE) $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_obj.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -I$(abspath $(NVN_TEST_DIR)/nvn/gen) -DNVN_VFMT_SOURCE='"$(abspath $(NVN_VFMT_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_vfmt_rgbx.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vfmt_rgbx
native-test-nvn_vfmt_rgbx: $(NVN_VFMT_BINARY)
	$(NVN_VFMT_BINARY)
TEST_TARGETS += native-test-nvn_vfmt_rgbx
endif
