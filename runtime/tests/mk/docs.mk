# native-test-docs：文档根唯一取法 runtime/include/s2a_docs.h（纯 C 头文件即实现），没有 runtime/src/docs.c，不走通用规则
NATIVE_TEST_OWN += docs
.PHONY: native-test-docs
native-test-docs:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_docs runtime/tests/t_docs.c
	$(BUILD)/tests/t_docs
TEST_TARGETS += native-test-docs
