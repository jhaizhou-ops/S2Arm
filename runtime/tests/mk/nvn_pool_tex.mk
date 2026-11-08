# native-test-nvn_pool_tex：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pool_tex
ifeq ($(shell uname -s),Darwin)
# 追不到槽的句柄读整个池（tex_pool / samp_pool：池表、已读位图、未写渲染目标不建、小贴图预建、表复用；Switch2 线 63，11-06）
$(BUILD)/tests/t_nvn_pool_tex: graphics/nvn/tests/t_nvn_pool_tex.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pool_tex.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pool_tex
native-test-nvn_pool_tex: $(BUILD)/tests/t_nvn_pool_tex
	$(BUILD)/tests/t_nvn_pool_tex
TEST_TARGETS += native-test-nvn_pool_tex
endif
