# native-test-ro_find：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ro_find
# 被测的是头文件 runtime/src/ro_find.h（没有同名 .c，不走通用规则）
.PHONY: native-test-ro_find
native-test-ro_find:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_ro_find runtime/tests/t_ro_find.c
	$(BUILD)/tests/t_ro_find
TEST_TARGETS += native-test-ro_find
