# native-test-nvn_red：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_red
ifeq ($(shell uname -s),Darwin)
# 采样器归约 / LOD 偏置按 GPU 能力原生或着色器模拟端到端（10-28，#800）：生产 dispatch + draw → se_want（判模拟位、从兜底目录载设备端变体 <键>_se.metal、按 function constant 特化）
#   → encode_args → se_bind（26 号槽）/ samp_by_id，本机能力（M5：原生 reductionMode / lodBias）vs S2A_SAMP_EMU=1（非 Apple10 那一路：着色器归约、加偏置）× Metal 4 / 3，
#   计算路径每路逐位等于 CPU 按定义手算的期望（含带偏置的归约 / 普通采样器）、片元路径两笔读数逐位等于手算；守卫：每条管线的模拟位 = 按定义要的、两项都原生时恒 0。
#   核原样与变体由 t_red.py --emit / --emit-fs 写（变体 = dmsh_red.py fs_rd，与设备上 S2A.Dsh FsRd 逐字同）。要 macOS 26
# 10-29 夜终版：归约变体不进库，设备上首遇后台编、编好前用 main0 替身（se_want / se_kick）：另两路 --async 核第一笔替身 / 编好后变体 / S2A_SE_SYNC=1 第一笔即变体，并核日志行格式
$(BUILD)/tests/t_nvn_red: graphics/nvn/tests/t_nvn_red.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_red.h graphics/nvn/gfx/nvn/nvn_pso_skey.h graphics/nvn/host/dsh_miss.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_red.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_red
native-test-nvn_red: $(BUILD)/tests/t_nvn_red
	python3 graphics/nvn/tests/t_red.py --emit $(BUILD)/tests/t_nvn_red.metal $(BUILD)/tests/t_nvn_red_se.metal
	python3 graphics/nvn/tests/t_red.py --emit-fs $(BUILD)/tests/t_nvn_red_fs.metal $(BUILD)/tests/t_nvn_red_fs_se.metal
	$(BUILD)/tests/t_nvn_red $(BUILD)/tests/t_nvn_red.metal $(BUILD)/tests/t_nvn_red_se.metal $(BUILD)/tests/t_nvn_red_fs.metal $(BUILD)/tests/t_nvn_red_fs_se.metal
TEST_TARGETS += native-test-nvn_red
endif
