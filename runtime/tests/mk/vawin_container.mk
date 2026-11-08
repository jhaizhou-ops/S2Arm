# native-test-vawin_container：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += vawin_container
ifeq ($(shell uname -s),Darwin)
# 多款容器构造期按各款取最大（vawin.c s2a_window_container_need）：链生产同一份 svc_mem / loader / layout / programs / imgpack；
#   这条路径用不到的宿主符号不链（-undefined dynamic_lookup，碰到即崩、单测报红）
.PHONY: native-test-vawin_container
native-test-vawin_container: $(TEST_VAGUARD)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_vawin_container runtime/tests/t_vawin_container.c runtime/src/vawin.c runtime/src/svc_mem.c runtime/src/loader.c runtime/src/layout.c runtime/src/programs.c runtime/src/imgpack.c -Wl,-undefined,dynamic_lookup -Wl,-weak_library,$(TEST_VAGUARD)
	$(BUILD)/tests/t_vawin_container
TEST_TARGETS += native-test-vawin_container
endif
