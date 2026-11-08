# native-test-nvn_wait_event：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_wait_event
ifeq ($(shell uname -s),Darwin)
# GPU 等事件（nvnCommandBufferWaitEvent）：已满足 / 同提交先信号不等；未满足在 GPU 上等到 CPU 写；超时强制放行
$(BUILD)/tests/t_nvn_wait_event: graphics/nvn/tests/t_nvn_wait_event.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_wait_event.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_wait_event
native-test-nvn_wait_event: $(BUILD)/tests/t_nvn_wait_event
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_wait_event
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_wait_event
TEST_TARGETS += native-test-nvn_wait_event
endif
