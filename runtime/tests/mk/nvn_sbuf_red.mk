# native-test-nvn_sbuf_red：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_sbuf_red
ifeq ($(shell uname -s),Darwin)
# 存储缓冲地址不在池里报红（审计 #1565 P1-112 读数缺口）
$(BUILD)/tests/t_nvn_sbuf_red: graphics/nvn/tests/t_nvn_sbuf_red.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_sbuf_red.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_sbuf_red
native-test-nvn_sbuf_red: $(BUILD)/tests/t_nvn_sbuf_red
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_sbuf_red
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_sbuf_red
TEST_TARGETS += native-test-nvn_sbuf_red
endif
