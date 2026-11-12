# native-test-nvn_rscale：直连内部分辨率（S2A_RES_SCALE）。生产 NVN bootstrap、录制、Metal 3/4 回放与公开读回；scaled（0.5）与 off（1）各跑一遍
# 另有 up（2）与 frac（1.5）：内部分辨率放开大于 1；25–29 组是窗口贴图（上屏标志）按倍率画与上屏 / 抓图 / 截图
NATIVE_TEST_OWN += nvn_rscale
ifeq ($(shell uname -s),Darwin)
# 单测把 nvn_mtl.m 编进本单元（第 8 组起挂手写着色器走计算派发 / 片元图像槽），依赖与编译选项同 t_nvn_pkg_gpu_write
$(BUILD)/tests/t_nvn_rscale: graphics/nvn/tests/t_nvn_rscale.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
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
	timeout 120 $(BUILD)/tests/t_nvn_rscale up
	timeout 120 $(BUILD)/tests/t_nvn_rscale frac
	NXGAL_BE=mtl3 timeout 120 $(BUILD)/tests/t_nvn_rscale up
	NXGAL_BE=mtl3 timeout 120 $(BUILD)/tests/t_nvn_rscale frac
	@echo '✓ t_nvn_rscale：Metal 4 / Metal 3 × 缩放 0.5 / 关 / 放大 2 / 放大 1.5 八遍各 29 组全过'
TEST_TARGETS += native-test-nvn_rscale
endif
