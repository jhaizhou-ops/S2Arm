# Exact production history functions and real NVN object/record/GPU lifetimes.
NATIVE_TEST_OWN += nvn_rt_history
ifeq ($(shell uname -s),Darwin)
NVN_RT_HISTORY_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_RT_HISTORY_BINARY ?= $(BUILD)/tests/t_nvn_rt_history
$(NVN_RT_HISTORY_BINARY): graphics/nvn/tests/t_nvn_rt_history.m $(NVN_RT_HISTORY_SOURCE) $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DNVN_RT_HISTORY_SOURCE='"$(abspath $(NVN_RT_HISTORY_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_rt_history.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rt_history
native-test-nvn_rt_history: $(NVN_RT_HISTORY_BINARY)
	DM_MTL3=0 $(NVN_RT_HISTORY_BINARY)
	DM_MTL3=1 $(NVN_RT_HISTORY_BINARY)
TEST_TARGETS += native-test-nvn_rt_history
endif
