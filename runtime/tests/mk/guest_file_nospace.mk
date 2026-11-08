# native-test-guest_file_nospace：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_file_nospace
ifeq ($(shell uname -s),Darwin)
# 客体内存文件后备的空间检查（vawin.c）：临时目录剩余空间不够时不接文件、照旧匿名（11-05 能耗线）
.PHONY: native-test-guest_file_nospace
native-test-guest_file_nospace: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_file_nospace runtime/tests/t_guest_file_nospace.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_file_nospace
TEST_TARGETS += native-test-guest_file_nospace
endif
