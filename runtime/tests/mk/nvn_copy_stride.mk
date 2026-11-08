# native-test-nvn_copy_stride：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_copy_stride
ifeq ($(shell uname -s),Darwin)
# 真实图标像素经生产 NVN 录制、Metal 拷贝与独立读回。
$(BUILD)/tests/t_nvn_copy_stride: graphics/nvn/tests/t_nvn_copy_stride.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_copy_stride.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_copy_stride
native-test-nvn_copy_stride: $(BUILD)/tests/t_nvn_copy_stride
	$(BUILD)/tests/t_nvn_copy_stride $(NVN_COPY_STRIDE_TEST_ARGS)
TEST_TARGETS += native-test-nvn_copy_stride
endif
