# native-test-widen：宽屏装载单测（runtime/src/widen.c 读补丁启用行，要连 runtime/src/patch.c；通用规则只连同名源文件）
NATIVE_TEST_OWN += widen
.PHONY: native-test-widen
native-test-widen:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_widen runtime/tests/t_widen.c runtime/src/widen.c runtime/src/patch.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_widen
TEST_TARGETS += native-test-widen
