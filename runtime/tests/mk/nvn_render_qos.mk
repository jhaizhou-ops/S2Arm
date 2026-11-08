# native-test-nvn_render_qos：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_render_qos
ifeq ($(shell uname -s),Darwin)
# 提交线程提到 USER_INTERACTIVE + 全进程调度档表 runtime/include/s2a_qos.h（11-06 Switch2 线 71：时之笛 Duo 提交线程 USER_INITIATED 落能效核）。
$(BUILD)/tests/t_nvn_render_qos: graphics/nvn/tests/t_nvn_render_qos.c graphics/nvn/gfx/nvn/nvn_protos.h runtime/include/s2a_qos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_render_qos.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_render_qos
native-test-nvn_render_qos: $(BUILD)/tests/t_nvn_render_qos
	timeout 60 $(BUILD)/tests/t_nvn_render_qos
TEST_TARGETS += native-test-nvn_render_qos
endif
