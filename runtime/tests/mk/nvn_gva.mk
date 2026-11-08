# native-test-nvn_gva：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_gva
ifeq ($(shell uname -s),Darwin)
# 池的 GPU 地址空间（hle_nvn.c gva_alloc / nvn_ga2ca）：缓冲区地址 64 KB 对齐、GPU 按它读写落到对的 CPU 存储、两池不重叠、释放后重建（十三机兵 11-01）
$(BUILD)/tests/t_nvn_gva: graphics/nvn/tests/t_nvn_gva.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_gva.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_gva
native-test-nvn_gva: $(BUILD)/tests/t_nvn_gva
	$(BUILD)/tests/t_nvn_gva
TEST_TARGETS += native-test-nvn_gva
endif
