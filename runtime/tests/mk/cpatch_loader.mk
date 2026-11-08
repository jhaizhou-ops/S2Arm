# 使用与宿主相同的完整原生生产对象；不提供 module / follow / loader 桩。
NATIVE_TEST_OWN += cpatch_loader
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_cpatch_loader: runtime/tests/t_cpatch_loader.c $(NVN_TEST_HOST_OBJS)
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $@ $< $(NVN_TEST_HOST_OBJS) $(S2A_HOST_WEAK)
.PHONY: native-test-cpatch_loader
native-test-cpatch_loader: $(BUILD)/tests/t_cpatch_loader
	python3 runtime/tests/cpatch_loader/prepare.py $(BUILD)/tests/cpatch_loader
	$(BUILD)/tests/t_cpatch_loader $(BUILD)/tests/cpatch_loader
TEST_TARGETS += native-test-cpatch_loader
endif
