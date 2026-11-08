# native-test-nvn_queue：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_queue
ifeq ($(shell uname -s),Darwin)
# 队列内存记账（#270 N12 Queue 组）：GetTotal{Command,Control,Compute}MemoryUsed 来自 builder 的三项、Reset 归零。
$(BUILD)/tests/t_nvn_queue: graphics/nvn/tests/t_nvn_queue.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_queue.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_queue
native-test-nvn_queue: $(BUILD)/tests/t_nvn_queue
	timeout 60 $(BUILD)/tests/t_nvn_queue
TEST_TARGETS += native-test-nvn_queue
endif
