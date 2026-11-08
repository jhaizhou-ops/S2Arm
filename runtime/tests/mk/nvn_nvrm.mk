# native-test-nvn_nvrm：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_nvrm
ifeq ($(shell uname -s),Darwin)
# nvnTextureGetNvRmSurfaceNVX：NVN 纹理描述成 NvRmSurface（织梦岛开场动画的视频解码写入纹理），字段照游戏 sdk 里真驱动的填法；池的 nvmap 句柄每池开一次
$(BUILD)/tests/t_nvn_nvrm: graphics/nvn/tests/t_nvn_nvrm.c graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_nvrm.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_nvrm
native-test-nvn_nvrm: $(BUILD)/tests/t_nvn_nvrm
	$(BUILD)/tests/t_nvn_nvrm
TEST_TARGETS += native-test-nvn_nvrm
endif
