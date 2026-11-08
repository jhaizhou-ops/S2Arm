# native-test-nvn_samp：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_samp
ifeq ($(shell uname -s),Darwin)
# Sampler / Buffer 调试与边界色（#270 N12）：整数边界色往返、调试 ID 稳定唯一。
$(BUILD)/tests/t_nvn_samp: graphics/nvn/tests/t_nvn_samp.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_samp.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_samp
native-test-nvn_samp: $(BUILD)/tests/t_nvn_samp
	timeout 60 $(BUILD)/tests/t_nvn_samp
TEST_TARGETS += native-test-nvn_samp
endif
