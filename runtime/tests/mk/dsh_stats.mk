# native-test-dsh_stats：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += dsh_stats
.PHONY: native-test-dsh_stats
native-test-dsh_stats:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -fblocks -pthread -o $(BUILD)/tests/t_dsh_stats graphics/nvn/tests/t_dsh_stats.c
	timeout 30 $(BUILD)/tests/t_dsh_stats
TEST_TARGETS += native-test-dsh_stats
