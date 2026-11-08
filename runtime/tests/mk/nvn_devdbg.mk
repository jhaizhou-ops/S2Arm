# native-test-nvn_devdbg：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_devdbg
ifeq ($(shell uname -s),Darwin)
# Device 调试接口组（#270 N12）：域号 / 外部调试器 / 标签 / 调试库遍历 / 检查点开关（空实现可调用）。
$(BUILD)/tests/t_nvn_devdbg: graphics/nvn/tests/t_nvn_devdbg.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_devdbg.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_devdbg
native-test-nvn_devdbg: $(BUILD)/tests/t_nvn_devdbg
	timeout 60 $(BUILD)/tests/t_nvn_devdbg
TEST_TARGETS += native-test-nvn_devdbg
endif
