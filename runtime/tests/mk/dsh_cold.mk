# native-test-dsh_cold：直连冷启动清兜底目录（graphics/nvn/host/dsh_cold.inc）单测
NATIVE_TEST_OWN += dsh_cold
.PHONY: native-test-dsh_cold
native-test-dsh_cold:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_dsh_cold graphics/nvn/tests/t_dsh_cold.c
	timeout 30 $(BUILD)/tests/t_dsh_cold
TEST_TARGETS += native-test-dsh_cold
