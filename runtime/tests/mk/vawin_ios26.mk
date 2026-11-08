# native-test-vawin_ios26：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_ios26
ifeq ($(shell uname -s),Darwin)
# 模拟 iOS 26 大地址档（S2A_VA_IOS26=1）：另一个进程验，窗口在构造函数里就定了
.PHONY: native-test-vawin_ios26
native-test-vawin_ios26: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_ios26 runtime/tests/t_vawin_ios26.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	S2A_VA_IOS26=1 $(BUILD)/tests/t_vawin_ios26
TEST_TARGETS += native-test-vawin_ios26
endif
