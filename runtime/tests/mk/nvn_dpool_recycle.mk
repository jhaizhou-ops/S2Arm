# native-test-nvn_dpool_recycle：本单测的构建规则（描述符池编号段复用）（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_dpool_recycle
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_dpool_recycle: graphics/nvn/tests/t_nvn_dpool_recycle.c graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_dpool_recycle.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_dpool_recycle
native-test-nvn_dpool_recycle: $(BUILD)/tests/t_nvn_dpool_recycle
	$(BUILD)/tests/t_nvn_dpool_recycle
TEST_TARGETS += native-test-nvn_dpool_recycle
endif
