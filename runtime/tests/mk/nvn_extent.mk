NATIVE_TEST_OWN += nvn_extent
ifeq ($(shell uname -s),Darwin)
NVN_EXTENT_BINARY ?= $(BUILD)/tests/t_nvn_extent
$(NVN_EXTENT_BINARY): graphics/nvn/tests/t_nvn_extent.m $(NVN_MTL_DEPS) graphics/nvn/texture_extent.inc graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(if $(NVN_EXTENT_BACKEND_SOURCE),-I$(dir $(NVN_EXTENT_BACKEND_SOURCE))../../host,) \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  $(if $(NVN_EXTENT_BACKEND_SOURCE),-DNVN_EXTENT_BACKEND_SOURCE='"$(NVN_EXTENT_BACKEND_SOURCE)"',) \
	  -o $@ graphics/nvn/tests/t_nvn_extent.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_extent
native-test-nvn_extent: $(NVN_EXTENT_BINARY)
	@for backend in mtl3 mtl4; do for mode in plain wide tall; do \
	  S2A_RES_SCALE=1 NXGAL_BE=$$backend tools/bin/timeout 60 $(NVN_EXTENT_BINARY) $$mode || exit $$?; \
	done; done
TEST_TARGETS += native-test-nvn_extent
endif
