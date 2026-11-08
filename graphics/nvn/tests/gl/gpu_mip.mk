# 作为第二份 makefile 复用 runtime/build.mk 的生产宿主 / NVN / NativeAOT 宽屏核心。
# GL_GPU_ARCHIVE 可链接保存的旧 GL 静态库，供同一测试核对修复前的失败；不改变生产代码。
GL_GPU_OUT ?= build/gl-gpu-mip
GL_GPU_TEST := $(GL_GPU_OUT)/t_gpu_mip
$(GL_GPU_TEST): graphics/nvn/tests/gl/t_gpu_mip.m $(GL_GPU_ARCHIVE) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) gl-gpu-mip-widen
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/gl/t_gpu_mip.m $(NVN_TEST_HOST_OBJS) $(GL_GPU_ARCHIVE) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,$(abspath $(dir $(NVN_TEST_WIDEN))) $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: gl-gpu-mip-build gl-gpu-mip-widen
gl-gpu-mip-build: $(GL_GPU_TEST)
# 沿用生产项目、产物路径与 NativeAOT 参数；依赖预先还原，测试本身不联网。
gl-gpu-mip-widen:
	dotnet publish graphics/widen/S2Arm.Gfx.Widen.csproj -c Release -r osx-arm64 -nodeReuse:false -p:UseSharedCompilation=false \
	  --artifacts-path $(abspath $(NVN_TEST_DIR)/widen-artifacts) \
	  -o $(abspath $(dir $(NVN_TEST_WIDEN))) -p:PublishAot=true -p:NativeLib=Shared -p:InvariantGlobalization=true
