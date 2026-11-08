# native-test-nvn_xqueue：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_xqueue
ifeq ($(shell uname -s),Darwin)
# 跨队列事件顺序（nvn_xqueue.inc nvn_be_submit）：等待之后的命令排在满足它的信号之后；互等报红不死锁
$(BUILD)/tests/t_nvn_xqueue: graphics/nvn/tests/t_nvn_xqueue.m graphics/nvn/gfx/nvn/nvn_mtl.m graphics/nvn/gfx/nvn/nvn_xqueue.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_xqueue.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_xqueue
native-test-nvn_xqueue: $(BUILD)/tests/t_nvn_xqueue
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_xqueue
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_xqueue
TEST_TARGETS += native-test-nvn_xqueue
endif
