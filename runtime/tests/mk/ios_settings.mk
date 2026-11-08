# native-test-ios_settings：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += ios_settings
.PHONY: native-test-ios_settings
native-test-ios_settings:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_ios_settings runtime/tests/t_ios_settings.m ios/settings.m runtime/src/caps.c runtime/src/patch.c runtime/src/launchctx.c
	$(BUILD)/tests/t_ios_settings ios/Settings.bundle/Root.plist
TEST_TARGETS += native-test-ios_settings
