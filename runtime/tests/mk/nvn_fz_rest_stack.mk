# native-test-nvn_fz_rest_stack：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_fz_rest_stack
ifeq ($(shell uname -s),Darwin)
# 往前看游标在 CALL 子列表内起步必须带回放返回栈（fz_cursor_from_exec）：子列表 END 后回到调用方续行，不跳 g_rest 走进外来内存（健身环 454 帧根因）
$(BUILD)/tests/t_nvn_fz_rest_stack: graphics/nvn/tests/t_nvn_fz_rest_stack.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_fz_rest_stack.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_fz_rest_stack
native-test-nvn_fz_rest_stack: $(BUILD)/tests/t_nvn_fz_rest_stack
	$(BUILD)/tests/t_nvn_fz_rest_stack
TEST_TARGETS += native-test-nvn_fz_rest_stack
endif
