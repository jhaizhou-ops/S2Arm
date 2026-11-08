# native-test-layout：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += layout
# 布局与内存SVC链接同一份生产布局实现。
.PHONY: native-test-layout
native-test-layout:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_layout runtime/tests/t_layout.c runtime/src/layout.c
	$(BUILD)/tests/t_layout
TEST_TARGETS += native-test-layout
