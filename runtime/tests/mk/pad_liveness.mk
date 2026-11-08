# native-test-pad_liveness：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 被测逻辑是 ios/pad_liveness.h（纯 C 头，无 UIKit / GameController 依赖），所以不走 runtime/src/<名>.c 的通用规则。
NATIVE_TEST_OWN += pad_liveness
.PHONY: native-test-pad_liveness
native-test-pad_liveness:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -Iios -o $(BUILD)/tests/t_pad_liveness runtime/tests/t_pad_liveness.c
	$(BUILD)/tests/t_pad_liveness ios/controller.m
TEST_TARGETS += native-test-pad_liveness
