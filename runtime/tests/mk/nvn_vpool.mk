# native-test-nvn_vpool：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_vpool
ifeq ($(shell uname -s),Darwin)
# 虚拟池一律按页表（hle_nvn.c vpool_*，11-03 火炬之光3 / Trine 5 / 无人深空）：不连续映射、负偏移、改映射、未映射建缓冲、超出预留、多池；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_vpool: graphics/nvn/tests/t_nvn_vpool.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_vpool.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vpool
native-test-nvn_vpool: $(BUILD)/tests/t_nvn_vpool
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_vpool
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_vpool
	@echo '✓ t_nvn_vpool：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_vpool
endif
