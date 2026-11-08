# 复用 runtime/build.mk 的生产宿主对象、NVN 直连库与真实 NativeAOT 宽屏核心。
# GL_MRT_ARCHIVE 可指定旧 GL 静态库，用同一回归核对修复前的缺口。
GL_MRT_OUT ?= build/gl-gpu-mrt/current
GL_MRT_ARCHIVE ?=
GL_MRT_TEST := $(GL_MRT_OUT)/t_gpu_mrt

$(GL_MRT_TEST): graphics/nvn/tests/gl/t_gpu_mrt.m $(GL_MRT_ARCHIVE) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) gl-gpu-mrt-widen
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/gl/t_gpu_mrt.m $(NVN_TEST_HOST_OBJS) $(GL_MRT_ARCHIVE) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,$(abspath $(dir $(NVN_TEST_WIDEN))) $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: gl-gpu-mrt-build gl-gpu-mrt-widen
gl-gpu-mrt-build: $(GL_MRT_TEST)
# 在本目标的产物路径还原；只用本机缓存，缺依赖报错，不隐式下载。
gl-gpu-mrt-widen:
	@mkdir -p $(NVN_TEST_DIR)/widen-offline-feed
	dotnet publish graphics/widen/S2Arm.Gfx.Widen.csproj -c Release -r osx-arm64 -nodeReuse:false -p:UseSharedCompilation=false \
	  -p:RestoreSources=$(abspath $(NVN_TEST_DIR)/widen-offline-feed) \
	  --artifacts-path $(abspath $(NVN_TEST_DIR)/widen-artifacts) \
	  -o $(abspath $(dir $(NVN_TEST_WIDEN))) -p:PublishAot=true -p:NativeLib=Shared -p:InvariantGlobalization=true
