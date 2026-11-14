NATIVE_TEST_OWN += nvn_present_init
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_present_init: graphics/nvn/tests/t_nvn_present_init.m graphics/nvn/tests/host_stubs.h $(NVN_TEST_LIB)
	$(MAKE) -s -C graphics/nvn OUT=$(abspath $(NVN_TEST_DIR)/nvn) widen-stubs
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -I$(NVN_TEST_DIR)/nvn/tests \
	  -o $@ graphics/nvn/tests/t_nvn_present_init.m $(NVN_TEST_LIB) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_present_init
native-test-nvn_present_init: $(BUILD)/tests/t_nvn_present_init
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_present_init
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_present_init
TEST_TARGETS += native-test-nvn_present_init
endif
