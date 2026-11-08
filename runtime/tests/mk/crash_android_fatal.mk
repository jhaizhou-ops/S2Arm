# native-test-crash_android_fatal：Android fatal 行 + 恢复处置重放 / 重 raise（宿主单测，macOS / Linux 都跑；不需要设备）
NATIVE_TEST_OWN += crash_android_fatal
.PHONY: native-test-crash_android_fatal
native-test-crash_android_fatal:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_crash_android_fatal runtime/tests/t_crash_android_fatal.c
	$(BUILD)/tests/t_crash_android_fatal
TEST_TARGETS += native-test-crash_android_fatal
