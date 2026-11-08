# Production slot-27 binding, observed on a full-precision GPU attachment.
NATIVE_TEST_OWN += nvn_color_round
ifeq ($(shell uname -s),Darwin)
NVN_COLOR_ROUND_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_COLOR_ROUND_BINARY ?= $(BUILD)/tests/t_nvn_color_round
$(NVN_COLOR_ROUND_BINARY): graphics/nvn/tests/t_nvn_color_round.m $(NVN_COLOR_ROUND_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -I$(abspath $(NVN_TEST_DIR)/nvn/gen) -DNVN_COLOR_ROUND_SOURCE='"$(abspath $(NVN_COLOR_ROUND_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_color_round.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_color_round
native-test-nvn_color_round: $(NVN_COLOR_ROUND_BINARY)
	$(NVN_COLOR_ROUND_BINARY)
TEST_TARGETS += native-test-nvn_color_round
endif
