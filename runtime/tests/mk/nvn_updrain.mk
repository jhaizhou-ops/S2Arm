# native-test-nvn_updrain：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_updrain
ifeq ($(shell uname -s),Darwin)
# 一次提交里连着上传多张 CPU 解排布贴图不卡死（up_begin 等槽之前先把录制交给编码线程；怪猎崛起真机第 721 帧停住 45 秒，10-26）
$(BUILD)/tests/t_nvn_updrain: graphics/nvn/tests/t_nvn_updrain.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_updrain.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_updrain
native-test-nvn_updrain: $(BUILD)/tests/t_nvn_updrain
	$(BUILD)/tests/t_nvn_updrain
TEST_TARGETS += native-test-nvn_updrain
endif
