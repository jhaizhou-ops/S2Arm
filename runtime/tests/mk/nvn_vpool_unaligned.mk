# native-test-nvn_vpool_unaligned：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_vpool_unaligned
ifeq ($(shell uname -s),Darwin)
# 虚拟池里 4 KB 对齐、16 KB 不对齐的映射：缓冲经页表副本让 GPU 读到（审计 #1592 P1-112，hle_nvn.c vsh_*）；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_vpool_unaligned: graphics/nvn/tests/t_nvn_vpool_unaligned.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_vpool_unaligned.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vpool_unaligned
native-test-nvn_vpool_unaligned: $(BUILD)/tests/t_nvn_vpool_unaligned
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_vpool_unaligned
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_vpool_unaligned
TEST_TARGETS += native-test-nvn_vpool_unaligned
endif
