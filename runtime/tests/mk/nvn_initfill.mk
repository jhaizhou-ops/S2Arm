# native-test-nvn_initfill：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_initfill
ifeq ($(shell uname -s),Darwin)
# 贴图初始内容（tex_init_fill）：CPU 可写池未 Flush 的新贴图读到存储内容；GPU 写过的不被旧字节覆盖（巫师3 10-26）
$(BUILD)/tests/t_nvn_initfill: graphics/nvn/tests/t_nvn_initfill.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_initfill.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_initfill
native-test-nvn_initfill: $(BUILD)/tests/t_nvn_initfill
	$(BUILD)/tests/t_nvn_initfill
TEST_TARGETS += native-test-nvn_initfill
endif
