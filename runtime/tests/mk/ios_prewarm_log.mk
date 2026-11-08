# native-test-ios_prewarm_log：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ios_prewarm_log
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-ios_prewarm_log
native-test-ios_prewarm_log:
	@mkdir -p $(BUILD)/tests/ios_prewarm_log
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/tests/support/ios_prewarm -Dgetenv=s2a_log_test_getenv -Dopen=s2a_log_test_open -Drename=s2a_log_test_rename -Ddup=s2a_log_test_dup -Ddup2=s2a_log_test_dup2 -c runtime/src/os.c -o $(BUILD)/tests/ios_prewarm_log/os.o
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_ios_prewarm_log runtime/tests/t_ios_prewarm_log.c $(BUILD)/tests/ios_prewarm_log/os.o
	bash runtime/tests/support/ios_prewarm/log_sessions.sh $(BUILD)/tests/t_ios_prewarm_log
TEST_TARGETS += native-test-ios_prewarm_log
endif
