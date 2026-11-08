# native-test-nvn_rec_bad：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rec_bad
ifeq ($(shell uname -s),Darwin)
# 命令流游标遇到不是我方写的记录头：打红行、结束该列表，不原地打转（健身环 11-03 第 454 帧回放读到 {op 2, size 0} 原地 80 秒）
$(BUILD)/tests/t_nvn_rec_bad: graphics/nvn/tests/t_nvn_rec_bad.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_rec_bad.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rec_bad
native-test-nvn_rec_bad: $(BUILD)/tests/t_nvn_rec_bad
	$(BUILD)/tests/t_nvn_rec_bad
TEST_TARGETS += native-test-nvn_rec_bad
endif
