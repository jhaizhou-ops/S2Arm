# native-test-hmap：nvn_hmap 对拍（8 字节键快路 / 20 字节键，随机 put / del / clear 与朴素模型比）；不需要 GPU / 游戏
NATIVE_TEST_OWN += hmap
.PHONY: native-test-hmap
native-test-hmap:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -o $(BUILD)/tests/t_hmap graphics/nvn/tests/t_hmap.c
	$(BUILD)/tests/t_hmap
TEST_TARGETS += native-test-hmap
