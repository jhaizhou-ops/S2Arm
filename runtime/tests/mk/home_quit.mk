# native-test-home_quit：#276 实体手柄按住 Home 退出的决策表 + front_mac.m 接线断言（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += home_quit
.PHONY: native-test-home_quit
native-test-home_quit:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_home_quit runtime/tests/t_home_quit.c
	$(BUILD)/tests/t_home_quit macos/front_mac.m
TEST_TARGETS += native-test-home_quit
