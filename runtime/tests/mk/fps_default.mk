# native-test-fps_default：present_interval 缺省推导单测
NATIVE_TEST_OWN += fps_default
.PHONY: native-test-fps_default
native-test-fps_default:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_fps_default runtime/tests/t_fps_default.c
	$(BUILD)/tests/t_fps_default
TEST_TARGETS += native-test-fps_default
