# native-test-nvn2：Switch 2（NVN2）宿主侧 nvn2.c——着色器键规则、sdk 里 NVN2 驱动设备信息跳表的扫描、设备值、GOB 内次序、nvn2_cmd.h 的推常量规整与 DLSS 布局 / 最佳尺寸；纯 C，不需要 GPU / 游戏
NATIVE_TEST_OWN += nvn2
.PHONY: native-test-nvn2
native-test-nvn2:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/host -o $(BUILD)/tests/t_nvn2 graphics/nvn/tests/t_nvn2.c graphics/nvn/gfx/nvn/nvn2.c graphics/nvn/gfx/tex/nvn_deswizzle.c graphics/nvn/gfx/nvn/nvn_tex.c
	$(BUILD)/tests/t_nvn2
TEST_TARGETS += native-test-nvn2
