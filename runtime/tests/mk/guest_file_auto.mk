# native-test-guest_file_auto：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += guest_file_auto
ifeq ($(shell uname -s),Darwin)
# 客体内存文件后备开不开（vawin.c s2a_guest_file_wanted）：显式 0 / 1、没设时 iOS 池大于剩余才开、Mac 没设关；真起局没设不接文件
.PHONY: native-test-guest_file_auto
native-test-guest_file_auto: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_guest_file_auto runtime/tests/t_guest_file_auto.c runtime/src/vawin.c -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_guest_file_auto
TEST_TARGETS += native-test-guest_file_auto
endif
