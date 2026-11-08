# Alternate phases use the production clock and platform implementation.
NATIVE_TEST_OWN += alt
.PHONY: native-test-alt
native-test-alt:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_alt runtime/tests/t_alt.c runtime/src/alt.c runtime/src/os.c $(APPLE_PLAT_SRCS)
	$(BUILD)/tests/t_alt
TEST_TARGETS += native-test-alt
