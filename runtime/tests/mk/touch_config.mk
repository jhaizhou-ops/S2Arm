# native-test-touch_config：游戏声明触屏配置 → 自动切仅触屏（ios/touch_config.m，Foundation 层，Mac 上编；vpad.m 切方案入口由单测桩掉）
NATIVE_TEST_OWN += touch_config
.PHONY: native-test-touch_config
native-test-touch_config:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_touch_config runtime/tests/t_touch_config.m
	$(BUILD)/tests/t_touch_config
TEST_TARGETS += native-test-touch_config
