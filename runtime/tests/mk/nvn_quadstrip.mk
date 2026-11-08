# native-test-nvn_quadstrip：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_quadstrip
ifeq ($(shell uname -s),Darwin)
# 四边形条带（无人深空 11-06：回放整笔丢掉）：公开 NVN 接口 DrawArrays / DrawElements 画四边形条带，按 GL 定义手算的红像素数判；直接包含生产 nvn_mtl.m；Metal 4 / Metal 3 × 编码线程关 / 开各跑一遍
$(BUILD)/tests/t_nvn_quadstrip: graphics/nvn/tests/t_nvn_quadstrip.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_quadstrip.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_quadstrip
native-test-nvn_quadstrip: $(BUILD)/tests/t_nvn_quadstrip
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_quadstrip
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_quadstrip
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_quadstrip
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_quadstrip
TEST_TARGETS += native-test-nvn_quadstrip
endif
