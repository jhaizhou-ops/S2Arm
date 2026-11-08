# native-test-nvn_tensor_sq：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tensor_sq
ifeq ($(shell uname -s),Darwin)
# 张量核网络顶替的输出域：平方域出口层先把输入平方再 MetalFX 放大（时之笛游玩画面发白）；Metal 4 编码线程关 / 开、Metal 3 各跑一遍
$(BUILD)/tests/t_nvn_tensor_sq: graphics/nvn/tests/t_nvn_tensor_sq.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tensor_sq.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tensor_sq
native-test-nvn_tensor_sq: $(BUILD)/tests/t_nvn_tensor_sq
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_tensor_sq
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_tensor_sq
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_tensor_sq
TEST_TARGETS += native-test-nvn_tensor_sq
endif
