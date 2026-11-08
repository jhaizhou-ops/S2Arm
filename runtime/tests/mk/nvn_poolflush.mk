# native-test-nvn_poolflush：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_poolflush
ifeq ($(shell uname -s),Darwin)
# 池 / 缓冲上的 Flush 发布 CPU 写过的贴图（hle_nvn.c ft_flush；缓冲转调池的刷新，缺口扫描 11-01 族 42）；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_poolflush: graphics/nvn/tests/t_nvn_poolflush.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_poolflush.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_poolflush
native-test-nvn_poolflush: $(BUILD)/tests/t_nvn_poolflush
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_poolflush
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_poolflush
	@echo '✓ t_nvn_poolflush：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_poolflush
endif
