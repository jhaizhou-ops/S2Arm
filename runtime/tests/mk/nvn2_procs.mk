# native-test-nvn2_procs：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn2_procs
ifeq ($(shell uname -s),Darwin)
# NVN2（Switch 2）驱动按名可取的 767 个入口全部取得到、未实现桩正好是写明原因的那些；11-04 补的各类入口按驱动布局 / 公式（期望来自驱动反汇编，见 t_nvn2_procs.c 头注释）。
$(BUILD)/tests/t_nvn2_procs: graphics/nvn/tests/t_nvn2_procs.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn2_cmd.h graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/nvn2_drv_names.txt $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn2_procs.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn2_procs
native-test-nvn2_procs: $(BUILD)/tests/t_nvn2_procs
	timeout 60 $(BUILD)/tests/t_nvn2_procs
TEST_TARGETS += native-test-nvn2_procs
endif
