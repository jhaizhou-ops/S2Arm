# native-test-ldn_lan：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 被测文件 ios/ldn_lan.m 由单测整份 #include（要直接驱动它的类、换上假的共用选举实现），所以不走 runtime/src/<名>.c 的通用规则、不链 lan_elect.c
NATIVE_TEST_OWN += ldn_lan
.PHONY: native-test-ldn_lan
native-test-ldn_lan:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -fobjc-arc -framework Foundation -o $(BUILD)/tests/t_ldn_lan runtime/tests/t_ldn_lan.m
	$(BUILD)/tests/t_ldn_lan
TEST_TARGETS += native-test-ldn_lan
