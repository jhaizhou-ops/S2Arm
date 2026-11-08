# Mac malloc 房间与生产远端围栏：真实地址探测，不需要游戏或 NPDM。
NATIVE_TEST_OWN += vawin_far
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-vawin_far
native-test-vawin_far: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -Wl,-dead_strip -Wl,-exported_symbol,_main -o $(BUILD)/tests/t_vawin_far runtime/tests/t_vawin_far.c runtime/src/vawin.c runtime/src/layout.c runtime/src/far.c -Wl,-weak_library,$(TEST_VAGUARD)
	@for mode in layout max-span; do env -u S2A_VAWIN_NORESERVE -u S2A_VA_CAP_MB -u S2A_VA_IOS26 S2A_WIN_NEED_MB=81920 S2A_IPHONE_VA=1 S2A_IPHONE_VA_DEDUCT_MB=0 $(BUILD)/tests/t_vawin_far $$mode || exit $$?; done
TEST_TARGETS += native-test-vawin_far
endif
