# native-test-programs：多程序合集的序号登记（runtime/src/programs.c；ExecuteProgram(n) 切到包里 programs/<n>/ 那支程序）
NATIVE_TEST_OWN += programs
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-programs
native-test-programs:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_programs runtime/tests/t_programs.c runtime/src/programs.c
	$(BUILD)/tests/t_programs
TEST_TARGETS += native-test-programs
endif
