# native-test-vawin：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin
ifeq ($(shell uname -s),Darwin)
# t_vaguard 的不带护栏反证仍保持独立，不由此规则改动。
.PHONY: native-test-vawin
native-test-vawin: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin runtime/tests/t_vawin.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin
TEST_TARGETS += native-test-vawin
endif
