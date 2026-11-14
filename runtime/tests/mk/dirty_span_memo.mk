# native-test-dirty_span_memo：写跟踪「取范围」线程内备忘（nvn_dirty.c find_span，#974 问 3）——
# 与线性扫逐位一致（含「没有」）/ 重复的键命中 / 表一变（登记 / 注销 / 复用槽位 / 换底 / 重置会话）旧记录作废 / 奇数代际不信不记 / 开关与容量 / 并发下读者线程不留旧答案。
# 直接包含生产源码（读静态的 find_span / find_span_scan，也让变异测试能换成变异副本：graphics/nvn/tests/dirty_span_memo_mutation_test.py）。不需要 GPU / 游戏。
NATIVE_TEST_OWN += dirty_span_memo
.PHONY: native-test-dirty_span_memo
native-test-dirty_span_memo:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iruntime/include -pthread -o $(BUILD)/tests/t_dirty_span_memo graphics/nvn/tests/t_dirty_span_memo.c
	$(BUILD)/tests/t_dirty_span_memo
TEST_TARGETS += native-test-dirty_span_memo
