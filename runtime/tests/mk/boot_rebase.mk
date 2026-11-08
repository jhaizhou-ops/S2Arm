# native-test-boot_rebase：起局计时起点改到点 Play（runtime/src/boot.c s2a_boot_rebase；多款容器库界面停留不计入起局）
NATIVE_TEST_OWN += boot_rebase
# boot.c 非安卓分支取进程创建时刻用 sysctl kern.proc（苹果）
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-boot_rebase
native-test-boot_rebase:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_boot_rebase runtime/tests/t_boot_rebase.c runtime/src/boot.c
	$(BUILD)/tests/t_boot_rebase
TEST_TARGETS += native-test-boot_rebase
endif
