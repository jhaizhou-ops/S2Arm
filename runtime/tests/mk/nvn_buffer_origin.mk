# #329 Metal 3 buffer-origin regression: real production host/NVN/Widen objects, no stubs.
NATIVE_TEST_OWN += nvn_buffer_origin
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_buffer_origin: graphics/nvn/tests/t_nvn_buffer_origin.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_buffer_origin.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_buffer_origin
native-test-nvn_buffer_origin: $(BUILD)/tests/t_nvn_buffer_origin
	$(BUILD)/tests/t_nvn_buffer_origin
TEST_TARGETS += native-test-nvn_buffer_origin
endif
