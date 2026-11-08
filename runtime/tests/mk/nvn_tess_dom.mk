# native-test-nvn_tess_dom：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tess_dom
ifeq ($(shell uname -s),Darwin)
# 曲面绘制的 hull 核按域载入（审计 #814 F-tess-dom-first）：有该域的核（<key>_b 或 <key>_b_t<域>）就用那份画、真画出可手算的像素；没有的 hull × 域组合跳过、计数、每组合报红一次
NVN_TESS_DOM_LIB := $(BUILD)/tests/tess_dom
$(NVN_TESS_DOM_LIB)/4444444444444444_b_t1.metallib: graphics/nvn/tests/t_nvn_tess_dom_t1.metal
	@mkdir -p $(dir $@)
	xcrun -sdk macosx metal $< -o $@
$(BUILD)/tests/t_nvn_tess_dom: graphics/nvn/tests/t_nvn_tess_dom.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tess_dom.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tess_dom
native-test-nvn_tess_dom: $(BUILD)/tests/t_nvn_tess_dom $(NVN_TESS_DOM_LIB)/4444444444444444_b_t1.metallib
	DM_NVN_ENC_THREAD=0 T_TESS_DOM_LIB=$(abspath $(NVN_TESS_DOM_LIB)) $(BUILD)/tests/t_nvn_tess_dom
	DM_NVN_ENC_THREAD=1 T_TESS_DOM_LIB=$(abspath $(NVN_TESS_DOM_LIB)) $(BUILD)/tests/t_nvn_tess_dom
TEST_TARGETS += native-test-nvn_tess_dom
endif
