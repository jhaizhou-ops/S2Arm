# nn::ro 装超过 256 个 NRO（11-03 大乱斗 764 个）：完整原生生产对象 + 出包 C 改写器产物，不提供 loader 桩。
NATIVE_TEST_OWN += nro_many
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nro_many: runtime/tests/t_nro_many.c $(NVN_TEST_HOST_OBJS)
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $@ $< $(NVN_TEST_HOST_OBJS) $(S2A_HOST_WEAK)
.PHONY: native-test-nro_many
native-test-nro_many: $(BUILD)/tests/t_nro_many
	python3 runtime/tests/nro_many/prepare.py $(BUILD)/tests/nro_many 300
	$(BUILD)/tests/t_nro_many $(BUILD)/tests/nro_many 300
TEST_TARGETS += native-test-nro_many
endif
