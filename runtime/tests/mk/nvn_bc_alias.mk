# native-test-nvn_bc_alias：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_bc_alias
ifeq ($(shell uname -s),Darwin)
# 块压缩贴图的未压缩别名（无人深空 GPU 压缩贴图彩虹噪点，11-06）：公开 NVN 接口建同存储的 BC1 与 RG32UI，GPU 写 RG32UI 后读 BC 贴图的块与像素，期望按 BC1 规则手算，含负对照；Metal 4 / Metal 3 × 编码线程关 / 开各跑一遍
$(BUILD)/tests/t_nvn_bc_alias: graphics/nvn/tests/t_nvn_bc_alias.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_bc_alias.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_bc_alias
native-test-nvn_bc_alias: $(BUILD)/tests/t_nvn_bc_alias
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_bc_alias
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_bc_alias
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_bc_alias
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_bc_alias
TEST_TARGETS += native-test-nvn_bc_alias
endif
