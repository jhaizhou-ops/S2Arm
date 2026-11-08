# native-test-nvn_devmode：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_devmode
ifeq ($(shell uname -s),Darwin)
# 窗口原点 / 深度模式按设备、后端跟提交队列的设备（11-03 弹丸论破V3 第二个设备初始化把主设备的左上原点改回左下）。
$(BUILD)/tests/t_nvn_devmode: graphics/nvn/tests/t_nvn_devmode.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_devmode.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_devmode
native-test-nvn_devmode: $(BUILD)/tests/t_nvn_devmode
	timeout 60 $(BUILD)/tests/t_nvn_devmode
TEST_TARGETS += native-test-nvn_devmode
endif
