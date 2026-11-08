# native-test-pic_watch：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += pic_watch
# 直连画面检查判据（graphics/nvn/host/pic_watch.inc，纯 C）。
.PHONY: native-test-pic_watch
native-test-pic_watch:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_pic_watch graphics/nvn/tests/t_pic_watch.c
	timeout 30 $(BUILD)/tests/t_pic_watch
TEST_TARGETS += native-test-pic_watch
