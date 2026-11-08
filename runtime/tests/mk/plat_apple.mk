# native-test-plat_apple：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += plat_apple
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-plat_apple
native-test-plat_apple:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_plat_apple runtime/tests/t_plat_apple.c platform/apple/plat_apple.c
	$(BUILD)/tests/t_plat_apple
TEST_TARGETS += native-test-plat_apple
endif
