# native-test-nvn_vicwrite：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_vicwrite
ifeq ($(shell uname -s),Darwin)
# 交出 NvRmSurface 的贴图按 VIC 写的字节重传（hle_nvn.c nvnTextureGetNvRmSurfaceNVX，11-03 幻想水浒影片不出帧）；GPU 写过的部分保留；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_vicwrite: graphics/nvn/tests/t_nvn_vicwrite.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_vicwrite.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_vicwrite
native-test-nvn_vicwrite: $(BUILD)/tests/t_nvn_vicwrite
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_vicwrite
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_vicwrite
	@echo '✓ t_nvn_vicwrite：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_vicwrite
endif
