# native-test-nvn_winding：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_winding
ifeq ($(shell uname -s),Darwin)
# 正面绕序 × 窗口原点 × 建队列时机（极品飞车直连黑车身，11-05）：公开 NVN 接口画一个三角形、剔背面，八种组合判画出 / 剔掉；直接包含生产 nvn_mtl.m；Metal 4 / Metal 3 × 编码线程关 / 开各跑一遍
$(BUILD)/tests/t_nvn_winding: graphics/nvn/tests/t_nvn_winding.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_winding.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_winding
native-test-nvn_winding: $(BUILD)/tests/t_nvn_winding
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_winding
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_winding
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_winding
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_winding
TEST_TARGETS += native-test-nvn_winding
endif
