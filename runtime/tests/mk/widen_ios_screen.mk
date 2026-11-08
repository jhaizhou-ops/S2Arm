# native-test-widen_ios_screen：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 用假 TargetConditionals.h（support/ios_prewarm：TARGET_OS_IPHONE 置 1）在 Mac 上执行真实 iOS 分支：
#   s2a_screen_w / s2a_screen_h 的「窗口场景还没连上」只读不缓存，在 Mac 上不打开这道门就永远测不到。
NATIVE_TEST_OWN += widen_ios_screen
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-widen_ios_screen
native-test-widen_ios_screen:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/tests/support/ios_prewarm -DS2A_UNIT_TEST -o $(BUILD)/tests/t_widen_ios_screen runtime/tests/t_widen_ios_screen.c runtime/src/widen.c runtime/src/patch.c
	$(BUILD)/tests/t_widen_ios_screen
TEST_TARGETS += native-test-widen_ios_screen
endif
