# native-test-nvn_icl：间接绘制参数拷贝核的夹紧（#2320）在真 GPU 上逐字比（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_icl
ifeq ($(S2A_UNAME),Darwin)
$(BUILD)/tests/t_nvn_icl: graphics/nvn/tests/t_nvn_icl.m graphics/nvn/gfx/nvn/nvn_mdx_msl.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ graphics/nvn/tests/t_nvn_icl.m -framework Metal -framework Foundation
.PHONY: native-test-nvn_icl
native-test-nvn_icl: $(BUILD)/tests/t_nvn_icl
	$(BUILD)/tests/t_nvn_icl
TEST_TARGETS += native-test-nvn_icl
endif
