# 本像素证明（scr_proof / uv_proof）的拒绝条件：左下角原点、视口 swizzle、视口不满等（10-30 帧率能耗线，画面线审）
NATIVE_TEST_OWN += nvn_screen_proof
ifeq ($(shell uname -s),Darwin)
NVN_PROOF_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
NVN_PROOF_BINARY ?= $(BUILD)/tests/t_nvn_screen_proof
$(NVN_PROOF_BINARY): graphics/nvn/tests/t_nvn_screen_proof.m $(NVN_PROOF_SOURCE) $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DNVN_PROOF_SOURCE='"$(abspath $(NVN_PROOF_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_nvn_screen_proof.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_screen_proof
native-test-nvn_screen_proof: $(NVN_PROOF_BINARY)
	$(NVN_PROOF_BINARY)
TEST_TARGETS += native-test-nvn_screen_proof
endif
