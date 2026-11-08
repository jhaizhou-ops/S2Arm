# native-test-nvn_alias_overwrite：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_alias_overwrite
ifeq ($(shell uname -s),Darwin)
# 同一存储上被别的贴图 GPU 写过的活对象贴图按 Ryujinx 语义释放（时之笛阴影图每帧换尺寸，429 张叠在 6 MB 存储上）；Metal 4 / 3 两路
$(BUILD)/tests/t_nvn_alias_overwrite: graphics/nvn/tests/t_nvn_alias_overwrite.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_alias_overwrite.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_alias_overwrite
native-test-nvn_alias_overwrite: $(BUILD)/tests/t_nvn_alias_overwrite
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_alias_overwrite
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_alias_overwrite
TEST_TARGETS += native-test-nvn_alias_overwrite
endif
