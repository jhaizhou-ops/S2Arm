# native-test-nvn_e：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_e
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_e: graphics/nvn/tests/t_nvn_e.c graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_e.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_e
native-test-nvn_e: $(BUILD)/tests/t_nvn_e
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_e
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_e
	@echo '✓ t_nvn_e：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_e
endif
