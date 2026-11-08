# native-test-nvn_firstuse：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_firstuse
ifeq ($(shell uname -s),Darwin)
# 首用取存储（tex_cpu_content / cpu_unc_drop，上游参考实现（MIT）37c7eaa8 + 75e5ddd8）：CPU 改写存储后同存储同描述新建的贴图读到新内容；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_firstuse: graphics/nvn/tests/t_nvn_firstuse.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_firstuse.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_firstuse
native-test-nvn_firstuse: $(BUILD)/tests/t_nvn_firstuse
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_firstuse
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_firstuse
	@echo '✓ t_nvn_firstuse：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_firstuse
endif
