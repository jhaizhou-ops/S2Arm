# native-test-nvn_ghost_sub：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_ghost_sub
ifeq ($(shell uname -s),Darwin)
# 已销毁纹理在一次提交里的去留（缺口 #3：幽灵环提交内保留、已销毁序号直解析共享纹理）
$(BUILD)/tests/t_nvn_ghost_sub: graphics/nvn/tests/t_nvn_ghost_sub.m $(NVN_MTL_DEPS) graphics/nvn/widen_glue.inc graphics/nvn/widen_fallback.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_ghost_sub.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ghost_sub
native-test-nvn_ghost_sub: $(BUILD)/tests/t_nvn_ghost_sub
	$(BUILD)/tests/t_nvn_ghost_sub
TEST_TARGETS += native-test-nvn_ghost_sub
endif
