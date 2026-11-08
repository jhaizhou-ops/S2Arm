# native-test-nvn_drvscan：游戏自带 NVN 驱动的 API 版本扫描（nvn_drvscan.h）：两种跳表派发的合成指令序列、无匹配与二义；不需要 GPU / 游戏
NATIVE_TEST_OWN += nvn_drvscan
.PHONY: native-test-nvn_drvscan
native-test-nvn_drvscan:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Igraphics/nvn/gfx/nvn -o $(BUILD)/tests/t_nvn_drvscan graphics/nvn/tests/t_nvn_drvscan.c
	$(BUILD)/tests/t_nvn_drvscan
TEST_TARGETS += native-test-nvn_drvscan
