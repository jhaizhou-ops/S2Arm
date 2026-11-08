# native-test-nvn_cut_busy：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_cut_busy
ifeq ($(shell uname -s),Darwin)
# 分段提交 GPU 忙时只留时间戳边界、不提交（上游参考实现（MIT）6121fd75）
$(BUILD)/tests/t_nvn_cut_busy: graphics/nvn/tests/t_nvn_cut_busy.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_cut_busy.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_cut_busy
native-test-nvn_cut_busy: $(BUILD)/tests/t_nvn_cut_busy
	$(BUILD)/tests/t_nvn_cut_busy
TEST_TARGETS += native-test-nvn_cut_busy
endif
