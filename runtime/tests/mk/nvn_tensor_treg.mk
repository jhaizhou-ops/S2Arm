# native-test-nvn_tensor_treg：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_tensor_treg
ifeq ($(shell uname -s),Darwin)
# 张量核网络顶替与登记表扩表并发（11-05 时之笛 tex_upgrade+0x4d4 崩溃）：生产 dispatch → tensor_standin 真跑 MetalFX，另一线程在 g_rmu 里 GROW(g_treg)；ASan 编译，读到旧表即中止；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_tensor_treg: graphics/nvn/tests/t_nvn_tensor_treg.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_tensor.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fsanitize=address -fno-omit-frame-pointer -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_tensor_treg.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_tensor_treg
native-test-nvn_tensor_treg: $(BUILD)/tests/t_nvn_tensor_treg
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_tensor_treg
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_tensor_treg
TEST_TARGETS += native-test-nvn_tensor_treg
endif
