# 装载器重定位分类（runtime/src/reloc_class.h）：TLS 四种留给游戏 sdk 的 nnmusl，其余不认识的照旧报红
NATIVE_TEST_OWN += reloc_class
.PHONY: native-test-reloc_class
native-test-reloc_class:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_reloc_class runtime/tests/t_reloc_class.c
	$(BUILD)/tests/t_reloc_class
TEST_TARGETS += native-test-reloc_class
