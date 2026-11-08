# native-test-nvn_frec_tex：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_frec_tex
ifeq ($(shell uname -s),Darwin)
# 帧录 GPU 贴图：深度模板 / 多重采样 / 压缩格式也存放
$(BUILD)/tests/t_nvn_frec_tex: graphics/nvn/tests/t_nvn_frec_tex.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_frec_tex.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_frec_tex
native-test-nvn_frec_tex: $(BUILD)/tests/t_nvn_frec_tex
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_frec_tex
TEST_TARGETS += native-test-nvn_frec_tex
endif
