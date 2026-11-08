# native-test-thread_plat：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += thread_plat
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-thread_plat
native-test-thread_plat:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -DS2A_TEST_REAL_PLAT -DS2A_THREAD_PLAT_VARIANT -o $(BUILD)/tests/t_thread_plat runtime/tests/t_thread_plat.c runtime/tests/t_thread.c runtime/src/thread.c platform/apple/plat_apple.c
	$(BUILD)/tests/t_thread_plat
TEST_TARGETS += native-test-thread_plat
endif
