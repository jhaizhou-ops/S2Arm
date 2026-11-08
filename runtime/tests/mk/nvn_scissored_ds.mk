NATIVE_TEST_OWN += nvn_scissored_ds
ifeq ($(shell uname -s),Darwin)
NVN_SCISSORED_DS_BINARY ?= $(BUILD)/tests/t_nvn_scissored_ds
$(NVN_SCISSORED_DS_BINARY): graphics/nvn/tests/t_nvn_scissored_ds.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(if $(NVN_SCISSORED_DS_SOURCE),-I$(dir $(NVN_SCISSORED_DS_SOURCE))../../host,) \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  $(if $(NVN_SCISSORED_DS_SOURCE),-DNVN_BACKEND_SOURCE='"$(NVN_SCISSORED_DS_SOURCE)"',) \
	  -o $@ graphics/nvn/tests/t_nvn_scissored_ds.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_scissored_ds
native-test-nvn_scissored_ds: $(NVN_SCISSORED_DS_BINARY)
	S2A_WIDEN_DIRECT=0 NXGAL_BE=mtl3 $(NVN_SCISSORED_DS_BINARY)
	S2A_WIDEN_DIRECT=0 NXGAL_BE=mtl4 $(NVN_SCISSORED_DS_BINARY)
TEST_TARGETS += native-test-nvn_scissored_ds
endif
