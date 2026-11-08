# native-test-nvn_fill：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_fill
ifeq ($(shell uname -s),Darwin)
# NVN 未实现函数批量补齐（10-25，#270）：设备 / 采样器边框色与调试 ID / 命令缓冲控制内存 / 缓冲调试 ID 的 CPU 侧语义
$(BUILD)/tests/t_nvn_fill: graphics/nvn/tests/t_nvn_fill.c graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_fill.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_fill
native-test-nvn_fill: $(BUILD)/tests/t_nvn_fill
	timeout 60 $(BUILD)/tests/t_nvn_fill
TEST_TARGETS += native-test-nvn_fill
endif
