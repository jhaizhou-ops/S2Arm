# native-test-buf_reg：活 nvnBuffer 区间表（nvn_buf_reg.h）与朴素模型对拍（重叠 / 同起点改长度 / 注销不存在）；增长率回归见 nvn_bufreg_rate.mk；不需要 GPU / 游戏
NATIVE_TEST_OWN += buf_reg
.PHONY: native-test-buf_reg
native-test-buf_reg:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_buf_reg graphics/nvn/tests/t_buf_reg.c
	$(BUILD)/tests/t_buf_reg
TEST_TARGETS += native-test-buf_reg
