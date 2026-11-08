# native-test-nvn_stale_fill：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_stale_fill
ifeq ($(shell uname -s),Darwin)
# CPU_NO_ACCESS 池里 GPU 写过的页、存有 Inf / NaN 的浮点存储都不当新贴图初始内容：完整 bootstrap、录制、Metal 3/4 回放与提交内拷出；DM_NVN_STALE_FILL=1 / DM_NVN_NONFINITE_FILL=1 反证旧行为。
$(BUILD)/tests/t_nvn_stale_fill: graphics/nvn/tests/t_nvn_stale_fill.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_stale_fill.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_stale_fill
native-test-nvn_stale_fill: $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl4 DM_NVN_STALE_FILL=1 $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl3 DM_NVN_STALE_FILL=1 $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl4 DM_NVN_NONFINITE_FILL=1 $(BUILD)/tests/t_nvn_stale_fill
	NXGAL_BE=mtl3 DM_NVN_NONFINITE_FILL=1 $(BUILD)/tests/t_nvn_stale_fill
TEST_TARGETS += native-test-nvn_stale_fill
endif
