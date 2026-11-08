# native-test-vawin_tail：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_tail
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-vawin_tail
native-test-vawin_tail: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_tail runtime/tests/t_vawin_tail.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_tail
TEST_TARGETS += native-test-vawin_tail
endif
