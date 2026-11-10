# native-test-touch_config：游戏声明触屏配置 → 自动切仅触屏（ios/touch_config.m，Foundation 层，Mac 上编；vpad.m 切方案入口由单测桩掉）
#   提示文案按 App 语言取（S2APICK，#316）：命令行程序的主 bundle 是程序所在目录，放进单独目录、旁边只放 zh-Hans.lproj 一种 = 中文，按中文期望核
#   （不和别的组共用 $(BUILD)/tests 下的 .lproj：门禁组并行，别组 rm -rf 重拷时这边会看到没有本地化、按英文取）
NATIVE_TEST_OWN += touch_config
.PHONY: native-test-touch_config
native-test-touch_config:
	@rm -rf $(BUILD)/tests/touch_config && mkdir -p $(BUILD)/tests/touch_config && cp -R ios/l10n/zh-Hans.lproj $(BUILD)/tests/touch_config/
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -fobjc-arc -framework Foundation -o $(BUILD)/tests/touch_config/t_touch_config runtime/tests/t_touch_config.m
	$(BUILD)/tests/touch_config/t_touch_config
TEST_TARGETS += native-test-touch_config
