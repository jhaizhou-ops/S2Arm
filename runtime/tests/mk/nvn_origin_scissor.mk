# native-test-nvn_origin_scissor：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_origin_scissor
ifeq ($(shell uname -s),Darwin)
# 审计缺口族 35：左上 / 左下角窗口原点下带裁剪的清屏落在同一批内存行（GL 约定，窗口 y 与贴图行同向）：完整 bootstrap、录制、Metal 3/4 回放与提交内拷出。
$(BUILD)/tests/t_nvn_origin_scissor: graphics/nvn/tests/t_nvn_origin_scissor.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_origin_scissor.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_origin_scissor
native-test-nvn_origin_scissor: $(BUILD)/tests/t_nvn_origin_scissor
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_origin_scissor
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_origin_scissor
	NXGAL_BE=mtl4 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_origin_scissor   # 延迟编码那一路（录制替身 DmRecEnc）
TEST_TARGETS += native-test-nvn_origin_scissor
endif
