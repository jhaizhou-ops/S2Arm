# native-test-nvn_f：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_f
ifeq ($(shell uname -s),Darwin)
# #270 F 组：公开 NVN 接口录制 -> 生产 Metal 回放 -> 真 GPU 读回，不使用宿主替身。
$(BUILD)/tests/t_nvn_f: graphics/nvn/tests/t_nvn_f.c graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_f.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_f
native-test-nvn_f: $(BUILD)/tests/t_nvn_f
	timeout 120 $(BUILD)/tests/t_nvn_f
TEST_TARGETS += native-test-nvn_f
endif
