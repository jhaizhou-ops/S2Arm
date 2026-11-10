# native-test-guest_file_pid：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_file_pid
ifeq ($(shell uname -s),Darwin)
# 审计 P1-139：构造期按 main.npdm 的程序号读本款实测峰值、不经 s2a_gfx_mode
.PHONY: native-test-guest_file_pid
native-test-guest_file_pid: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_file_pid runtime/tests/t_guest_file_pid.c runtime/src/vawin.c -Wl,-export_dynamic -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_file_pid
TEST_TARGETS += native-test-guest_file_pid
endif
