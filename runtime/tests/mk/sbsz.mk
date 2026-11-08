# native-test-sbsz：存储缓冲大小表（graphics/nvn/gfx/nvn/nvn_refl.h nvn_sbsz_fill，纯 C header-only）几何辅助缓冲按本笔临时区段长进表（11-06 鬼灭 #37）
NATIVE_TEST_OWN += sbsz
.PHONY: native-test-sbsz
native-test-sbsz:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=gnu11 -Wall -Wno-unused-function -o $(BUILD)/tests/t_sbsz graphics/nvn/tests/t_sbsz.c
	$(BUILD)/tests/t_sbsz
TEST_TARGETS += native-test-sbsz
