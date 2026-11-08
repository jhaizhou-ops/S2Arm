# native-test-vawin_need：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_need
ifeq ($(shell uname -s),Darwin)
# 窗口放不下（本款跨度 80 GB > 2^39 以下最大空洞）：另一个进程验，窗口在构造函数里就定了
.PHONY: native-test-vawin_need
native-test-vawin_need: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_need runtime/tests/t_vawin_need.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_need
TEST_TARGETS += native-test-vawin_need
endif
