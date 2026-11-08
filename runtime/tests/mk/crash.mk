# native-test-crash：崩溃现场单测（回溯、两段式第一段）。crash.c 引用的写跟踪 / 远端 / 直连等钩子在回溯路径上都不调，按动态查找留空（只 Mac）
NATIVE_TEST_OWN += crash
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-crash
native-test-crash:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_crash runtime/tests/t_crash.c runtime/src/crash.c platform/apple/plat_apple.c -Wl,-undefined,dynamic_lookup
	$(BUILD)/tests/t_crash
TEST_TARGETS += native-test-crash
endif
