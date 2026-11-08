NATIVE_TEST_OWN += dirty_reset
ifeq ($(shell uname -s),Darwin)
NVN_DIRTY_RESET_SOURCE ?= graphics/nvn/gfx/nvn/nvn_dirty.c
NVN_DIRTY_RESET_BINARY ?= $(BUILD)/tests/t_dirty_reset
$(NVN_DIRTY_RESET_BINARY): graphics/nvn/tests/t_dirty_reset.c $(NVN_DIRTY_RESET_SOURCE) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $@ graphics/nvn/tests/t_dirty_reset.c $(NVN_DIRTY_RESET_SOURCE) \
	  $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-dirty_reset
native-test-dirty_reset: $(NVN_DIRTY_RESET_BINARY)
	S2A_GFX=direct $(NVN_DIRTY_RESET_BINARY)
TEST_TARGETS += native-test-dirty_reset
endif
