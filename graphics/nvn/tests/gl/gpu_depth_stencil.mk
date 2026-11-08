# 真实生产宿主 / NVN / NativeAOT Widen；旧 GL archive 可优先解析以保存失败。
GL_DS_OUT ?= build/gl-depth-stencil/current
GL_DS_ARCHIVE ?=
GL_DS_BASELINE ?= 0
GL_DS_TEST := $(GL_DS_OUT)/t_gpu_depth_stencil
ifeq ($(GL_DS_BASELINE),1)
GL_DS_NVN_LIB_DEP :=
else
GL_DS_NVN_LIB_DEP := $(NVN_TEST_LIB)
endif
$(GL_DS_TEST): graphics/nvn/tests/gl/t_gpu_depth_stencil.m $(GL_DS_ARCHIVE) $(NVN_TEST_HOST_OBJS) $(GL_DS_NVN_LIB_DEP) gl-depth-stencil-widen
	@mkdir -p $(dir $@)
	@test -f "$(NVN_TEST_LIB)" || { echo "missing existing production NVN library: $(NVN_TEST_LIB)" >&2; exit 1; }
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/gl/t_gpu_depth_stencil.m $(NVN_TEST_HOST_OBJS) $(GL_DS_ARCHIVE) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,$(abspath $(dir $(NVN_TEST_WIDEN))) $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: gl-depth-stencil-build gl-depth-stencil-widen
gl-depth-stencil-build: $(GL_DS_TEST)
gl-depth-stencil-widen:
	@mkdir -p $(NVN_TEST_DIR)/widen-offline-feed
	# 只用已安装 / 已缓存依赖；缺依赖报错，测试不隐式下载。
	dotnet publish graphics/widen/S2Arm.Gfx.Widen.csproj -c Release -r osx-arm64 -nodeReuse:false -p:UseSharedCompilation=false \
	  -p:RestoreSources=$(abspath $(NVN_TEST_DIR)/widen-offline-feed) \
	  --artifacts-path $(abspath $(NVN_TEST_DIR)/widen-artifacts) \
	  -o $(abspath $(dir $(NVN_TEST_WIDEN))) -p:PublishAot=true -p:NativeLib=Shared -p:InvariantGlobalization=true
