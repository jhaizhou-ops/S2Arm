# native-test-vaguard：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vaguard
ifeq ($(shell uname -s),Darwin)
.PHONY: native-test-vaguard
native-test-vaguard: $(VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -dynamiclib -install_name @executable_path/libfake_xzm.dylib -o $(BUILD)/tests/libfake_xzm.dylib runtime/tests/support/fake_xzm.c
	cp -f $(VAGUARD) $(BUILD)/tests/libs2a_vaguard.dylib
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vaguard runtime/tests/t_vaguard.c runtime/src/vawin.c -Wl,-weak_library,$(BUILD)/tests/libs2a_vaguard.dylib $(BUILD)/tests/libfake_xzm.dylib
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vaguard_old runtime/tests/t_vaguard.c runtime/src/vawin.c $(BUILD)/tests/libfake_xzm.dylib
	$(CC) $(CFLAGS) -dynamiclib -install_name @executable_path/libfake_mmapfail.dylib -o $(BUILD)/tests/libfake_mmapfail.dylib runtime/tests/support/fake_mmapfail.c
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vaguard_fail runtime/tests/t_vaguard.c runtime/src/vawin.c -Wl,-weak_library,$(BUILD)/tests/libs2a_vaguard.dylib $(BUILD)/tests/libfake_xzm.dylib $(BUILD)/tests/libfake_mmapfail.dylib
	S2A_IPHONE_VA=0 $(BUILD)/tests/t_vaguard_old noguard
	S2A_IPHONE_VA=0 S2A_VAWIN_NORESERVE=1 $(BUILD)/tests/t_vaguard noreserve
	S2A_IPHONE_VA=0 $(BUILD)/tests/t_vaguard_fail mmapfail 2> $(BUILD)/tests/t_vaguard_fail.log
	@grep -q '占不到（失败 errno=12）' $(BUILD)/tests/t_vaguard_fail.log && echo "· t_vaguard mmapfail：日志 errno=12（mmap 后立即取）" || { echo "✗ t_vaguard mmapfail：日志里应是 errno=12，实为：$$(grep -o 'errno=[0-9]*' $(BUILD)/tests/t_vaguard_fail.log | head -1)"; exit 1; }
	S2A_IPHONE_VA=0 $(BUILD)/tests/t_vaguard guard
TEST_TARGETS += native-test-vaguard
endif
