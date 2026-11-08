NATIVE_TEST_OWN += dirty_growth
ifeq ($(shell uname -s),Darwin)
NVN_DIRTY_GROWTH_SOURCE ?= graphics/nvn/gfx/nvn/nvn_dirty.c
NVN_DIRTY_GROWTH_BINARY ?= $(BUILD)/tests/t_dirty_growth
$(NVN_DIRTY_GROWTH_BINARY): graphics/nvn/tests/t_dirty_growth.c $(NVN_DIRTY_GROWTH_SOURCE) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(NATIVE_INC) -DNVN_DIRTY_GROWTH_SOURCE='"$(abspath $(NVN_DIRTY_GROWTH_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_dirty_growth.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-dirty_growth
native-test-dirty_growth: $(NVN_DIRTY_GROWTH_BINARY)
	S2A_GFX=direct $(NVN_DIRTY_GROWTH_BINARY)
TEST_TARGETS += native-test-dirty_growth
endif
