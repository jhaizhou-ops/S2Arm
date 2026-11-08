# native-test-vawin_astype：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_astype
ifeq ($(shell uname -s),Darwin)
# 跨度为 0 时的红行按事实分（NPDM 地址空间类型不是 3 / 读不到 / 模块段算不出）：子进程验，窗口在构造函数里就定了
.PHONY: native-test-vawin_astype
native-test-vawin_astype: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_astype runtime/tests/t_vawin_astype.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_astype
TEST_TARGETS += native-test-vawin_astype
endif
