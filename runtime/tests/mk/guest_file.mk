# native-test-guest_file：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_file
ifeq ($(shell uname -s),Darwin)
# 客体内存文件后备（S2A_GUEST_FILE，vawin.c）：窗口换成临时文件 MAP_SHARED 映射后，脏页不计实占、还页打洞读回 0、vm_remap 别名一致
.PHONY: native-test-guest_file
native-test-guest_file: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_file runtime/tests/t_guest_file.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_file
TEST_TARGETS += native-test-guest_file
endif
