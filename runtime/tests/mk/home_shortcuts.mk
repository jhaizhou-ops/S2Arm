# native-test-home_shortcuts：主屏长按快捷操作（ios/shortcuts.json、runtime/build.mk 写 Info.plist、ios/app.m home_shortcut）
NATIVE_TEST_OWN += home_shortcuts
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-home_shortcuts
native-test-home_shortcuts:
	@bash runtime/tests/t_home_shortcuts.sh
	@$(IOS_CC) -fsyntax-only -fobjc-arc $(NATIVE_INC) -Iruntime/src -Iruntime/ns2pro/include ios/app.m ios/diag.m
endif
