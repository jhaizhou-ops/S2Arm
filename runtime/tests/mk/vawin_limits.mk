# 地址空洞统计必须遵守 TASK_VM_INFO 上限；只替换查询，不模拟 VM 映射。
NATIVE_TEST_OWN += vawin_limits
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-vawin_limits
native-test-vawin_limits: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -Dtask_info=s2a_test_task_info -c runtime/src/vawin.c -o $(BUILD)/tests/vawin_limits.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_limits runtime/tests/t_vawin_limits.c $(BUILD)/tests/vawin_limits.o -Wl,-weak_library,$(TEST_VAGUARD)
	S2A_VAWIN_NORESERVE=1 $(BUILD)/tests/t_vawin_limits
TEST_TARGETS += native-test-vawin_limits
endif
