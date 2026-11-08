# native-test-nvn_win：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_win
ifeq ($(shell uname -s),Darwin)
# 窗口纹理计数（#270 N12 Window 组）：GetNumTextures / GetNumActiveTextures。
$(BUILD)/tests/t_nvn_win: graphics/nvn/tests/t_nvn_win.c graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_win.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_win
native-test-nvn_win: $(BUILD)/tests/t_nvn_win
	timeout 60 $(BUILD)/tests/t_nvn_win
TEST_TARGETS += native-test-nvn_win
endif
