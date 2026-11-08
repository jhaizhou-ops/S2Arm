# Real GLSL / production reflection / NVN / NativeAOT Widen; no GPU substitutes.
NATIVE_TEST_OWN += nvn_image_atomic
ifeq ($(shell uname -s),Darwin)
NVN_IA_OUT := $(abspath $(NVN_TEST_DIR)/image-atomic)
NVN_IA_DSH := $(NVN_IA_OUT)/dsh-bin/dsh_cmp.dll
NVN_IA_ASSETS := $(NVN_IA_OUT)/assets
NVN_IA_SRC := graphics/nvn/tests/image_atomic
NVN_IA_PY := $(if $(S2A_PY),$(S2A_PY),python3)
$(NVN_IA_DSH): $(wildcard graphics/tools/direct/dsh/*.cs) graphics/tools/direct/dsh/S2A.Dsh.csproj \
    graphics/tools/direct/tests/dsh_cmp/Program.cs graphics/tools/direct/tests/dsh_cmp/Fn.cs \
    graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj graphics/nvn/gfx/nvn/dmsh_chain.h
	@mkdir -p $(NVN_IA_OUT)/empty-feed
	dotnet restore graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj --artifacts-path $(NVN_IA_OUT)/dsh-artifacts \
	  --source $(NVN_IA_OUT)/empty-feed > $(NVN_IA_OUT)/dsh-restore.log 2>&1
	dotnet build graphics/tools/direct/tests/dsh_cmp/dsh_cmp.csproj -c Release -nodeReuse:false -p:UseSharedCompilation=false --no-restore \
	  --artifacts-path $(NVN_IA_OUT)/dsh-artifacts -o $(NVN_IA_OUT)/dsh-bin \
	  -p:UseSharedCompilation=false > $(NVN_IA_OUT)/dsh-build.log 2>&1
$(NVN_IA_ASSETS)/generated.stamp: $(wildcard $(NVN_IA_SRC)/*.comp) $(NVN_IA_SRC)/generate.py $(NVN_IA_DSH)
	$(NVN_IA_PY) $(NVN_IA_SRC)/generate.py --out $(NVN_IA_ASSETS) --dsh $(NVN_IA_DSH)
$(BUILD)/tests/t_nvn_image_atomic: graphics/nvn/tests/t_nvn_image_atomic.m $(NVN_MTL_DEPS) \
    graphics/nvn/gfx/nvn/nvn_refl.m graphics/nvn/gfx/nvn/nvn_refl.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) $(NVN_IA_ASSETS)/generated.stamp
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_image_atomic.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_image_atomic
native-test-nvn_image_atomic: $(BUILD)/tests/t_nvn_image_atomic
	$(NVN_IA_PY) $(NVN_IA_SRC)/run.py --binary $(BUILD)/tests/t_nvn_image_atomic --assets $(NVN_IA_ASSETS) \
	  --out $(NVN_IA_OUT)/run-$$(date +%Y%m%dT%H%M%S)-$$$$
TEST_TARGETS += native-test-nvn_image_atomic
endif
