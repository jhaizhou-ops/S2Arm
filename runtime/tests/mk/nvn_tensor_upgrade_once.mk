# native-test-nvn_tensor_upgrade_once：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tensor_upgrade_once
ifeq ($(shell uname -s),Darwin)
# 张量核网络顶替的输出图登记带通道重排（如 R11G11B10F 的 a = 1）：每帧都「升级成可当渲染目标」、新建并整张拷贝（11-05 时之笛第二十版 ser=4149 升级 4354 次）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_tensor_upgrade_once: graphics/nvn/tests/t_nvn_tensor_upgrade_once.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_tensor.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tensor_upgrade_once.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tensor_upgrade_once
native-test-nvn_tensor_upgrade_once: $(BUILD)/tests/t_nvn_tensor_upgrade_once
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_tensor_upgrade_once
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_tensor_upgrade_once
TEST_TARGETS += native-test-nvn_tensor_upgrade_once
endif
