# Real fps.c with fake platform memory, clock and thread-name endpoints.
NATIVE_TEST_OWN += fps_portable
.PHONY: native-test-fps_portable
native-test-fps_portable:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -pthread -o $(BUILD)/tests/t_fps_portable runtime/tests/t_fps_portable.c runtime/src/fps.c
	$(BUILD)/tests/t_fps_portable
TEST_TARGETS += native-test-fps_portable
