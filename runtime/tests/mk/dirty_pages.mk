# native-test-dirty_pages：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += dirty_pages
.PHONY: native-test-dirty_pages
native-test-dirty_pages:   # 写跟踪列脏页（nvn_dirty_written_pages）：真写保护缺页，不需要 GPU / 游戏
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -o $(BUILD)/tests/t_dirty_pages graphics/nvn/tests/t_dirty_pages.c graphics/nvn/gfx/nvn/nvn_dirty.c
	$(BUILD)/tests/t_dirty_pages
TEST_TARGETS += native-test-dirty_pages
