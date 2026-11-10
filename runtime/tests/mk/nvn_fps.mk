# native-test-nvn_fps：帧率上限取值（graphics/nvn/gfx/nvn/nvn_fps.c）。纯 C，不要 GPU / Metal：起局读环境那一次每个取值起一个子进程（坏值要 abort）
NATIVE_TEST_OWN += nvn_fps
.PHONY: native-test-nvn_fps
native-test-nvn_fps:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_nvn_fps graphics/nvn/tests/t_nvn_fps.c graphics/nvn/gfx/nvn/nvn_fps.c -lm -lpthread
	timeout 30 $(BUILD)/tests/t_nvn_fps
TEST_TARGETS += native-test-nvn_fps
