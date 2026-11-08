# native-test-nvn2_codec：Switch 2 直连档的视频解码接管 nvn2_codec.c——图像池、VP9（libvpx，services/vpx 同一份库）/ AV1（VideoToolbox；没有 AV1 硬件解码的机器跳过并说明；
#   dav1d 软解逐帧 MD5 对 ffmpeg 参考、强制软解走整条路径）
#   解码器协议、H.264 未接回失败、同步点事件、av1C、NVN2 原生图像 → 线性纹理；纯 C + 替身，不需要游戏
NATIVE_TEST_OWN += nvn2_codec
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-nvn2_codec
native-test-nvn2_codec:
	@mkdir -p $(BUILD)/tests
	vpx=$$(bash services/vpx/build.sh osx-arm64 | tail -1) && [ -f "$$vpx" ] && dav1d=$$(bash services/dav1d/build.sh osx-arm64 | tail -1) && [ -f "$$dav1d" ] && \
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/host -o $(BUILD)/tests/t_nvn2_codec \
	  graphics/nvn/tests/t_nvn2_codec.c graphics/nvn/gfx/nvn/nvn2_codec.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c "$$vpx" "$$dav1d" \
	  -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation
	timeout 60 $(BUILD)/tests/t_nvn2_codec
TEST_TARGETS += native-test-nvn2_codec
endif
