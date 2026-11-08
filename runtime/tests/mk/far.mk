# native-test-far：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += far
# 远端影子：缺页代执行要链读 / 写模拟器
.PHONY: native-test-far
native-test-far:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_far runtime/tests/t_far.c runtime/src/far.c runtime/src/emul_ld.c runtime/src/emul_st.c
	S2A_DOCS=$(BUILD)/tests $(BUILD)/tests/t_far
TEST_TARGETS += native-test-far
