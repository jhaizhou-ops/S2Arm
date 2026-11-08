NATIVE_TEST_OWN += layout_balanced
.PHONY: native-test-layout_balanced
native-test-layout_balanced:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_layout_default runtime/tests/t_layout_balanced.c
	$(BUILD)/tests/t_layout_default
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -DS2A_VAMM_BALANCED=1 -o $(BUILD)/tests/t_layout_balanced runtime/tests/t_layout_balanced.c
	$(BUILD)/tests/t_layout_balanced
TEST_TARGETS += native-test-layout_balanced
