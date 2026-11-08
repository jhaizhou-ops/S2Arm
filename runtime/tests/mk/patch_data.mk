# native-test-patch_data：补丁包 [data] 段单测（runtime/src/patch_data.c；写入复用 cpatch.c，与满屏数据点避让要连 widen.c，解析在 patch.c）
NATIVE_TEST_OWN += patch_data
.PHONY: native-test-patch_data
native-test-patch_data:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_patch_data runtime/tests/t_patch_data.c runtime/src/patch_data.c runtime/src/cpatch.c runtime/src/widen.c runtime/src/patch.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_patch_data
TEST_TARGETS += native-test-patch_data
