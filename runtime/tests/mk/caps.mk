# native-test-caps：包内能力清单单测（runtime/src/caps.c；10-28 全能力出包，原先没接进门禁）
NATIVE_TEST_OWN += caps
.PHONY: native-test-caps
native-test-caps:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_caps runtime/tests/t_caps.c runtime/src/caps.c runtime/src/patch.c
	$(BUILD)/tests/t_caps
TEST_TARGETS += native-test-caps
