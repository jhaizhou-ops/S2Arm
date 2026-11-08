# native-test-game_tsv：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += game_tsv
# 直连现编适配的纯 C 计数/依赖边界（不需要 GPU、游戏或 C#）。
.PHONY: native-test-game_tsv
native-test-game_tsv:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_game_tsv graphics/nvn/tests/t_game_tsv.c
	$(BUILD)/tests/t_game_tsv
	python3 tests/game_tsv_test.py $(BUILD)/tests/t_game_tsv
TEST_TARGETS += native-test-game_tsv
