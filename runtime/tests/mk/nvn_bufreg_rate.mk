# native-test-nvn_bufreg_rate：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_bufreg_rate
ifeq ($(shell uname -s),Darwin)
# 缓冲建删增长率（hle_nvn.c nvnBufferInitialize / Finalize 的活缓冲登记，11-07 时之笛 30 → 5 帧）：N 与 4N 个缓冲耗时比 ≤ 8，单线程 / 4 线程各一遍；不设绝对耗时上限；缺省 = 安卓路线（强制登记、查长度全对），metal = Metal 路线（零登记）
$(BUILD)/tests/t_nvn_bufreg_rate: graphics/nvn/tests/t_nvn_bufreg_rate.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_bufreg_rate.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_bufreg_rate
native-test-nvn_bufreg_rate: $(BUILD)/tests/t_nvn_bufreg_rate
	$(BUILD)/tests/t_nvn_bufreg_rate
	$(BUILD)/tests/t_nvn_bufreg_rate metal
TEST_TARGETS += native-test-nvn_bufreg_rate
endif
