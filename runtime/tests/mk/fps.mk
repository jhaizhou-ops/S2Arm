# Test the real FPS core with the Apple platform and a standalone loader boundary.
NATIVE_TEST_OWN += fps
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-fps
native-test-fps:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -pthread -o $(BUILD)/tests/t_fps runtime/tests/t_fps.c runtime/src/fps.c platform/apple/plat_apple.c runtime/tests/support/key_page_fixture.c
	$(BUILD)/tests/t_fps
TEST_TARGETS += native-test-fps
endif
