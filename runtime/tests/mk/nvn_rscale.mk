# native-test-nvn_rscale：直连内部分辨率（S2A_RES_SCALE）。生产 NVN bootstrap、录制、Metal 3/4 回放与公开读回；scaled（0.5）与 off（1）各跑一遍
NATIVE_TEST_OWN += nvn_rscale
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_rscale: graphics/nvn/tests/t_nvn_rscale.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_rscale.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rscale
native-test-nvn_rscale: $(BUILD)/tests/t_nvn_rscale
	timeout 120 $(BUILD)/tests/t_nvn_rscale scaled
	timeout 120 $(BUILD)/tests/t_nvn_rscale off
	NXGAL_BE=mtl3 timeout 120 $(BUILD)/tests/t_nvn_rscale scaled
	NXGAL_BE=mtl3 timeout 120 $(BUILD)/tests/t_nvn_rscale off
	@echo '✓ t_nvn_rscale：Metal 4 / Metal 3 × 缩放 0.5 / 关 四遍各 6 组全过'
TEST_TARGETS += native-test-nvn_rscale
endif
