# native-test-svc_mem：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += svc_mem
# 布局与内存SVC链接同一份生产布局实现。
.PHONY: native-test-svc_mem
native-test-svc_mem: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_svc_mem runtime/tests/t_svc_mem.c runtime/src/svc_mem.c runtime/src/layout.c $(TEST_VAGUARD)
	$(BUILD)/tests/t_svc_mem
TEST_TARGETS += native-test-svc_mem
