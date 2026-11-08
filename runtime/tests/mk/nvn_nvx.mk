# native-test-nvn_nvx：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_nvx
ifeq ($(shell uname -s),Darwin)
# 驱动名字全集按名可取且有实现 + 11-03 补的 29 个 NVX / 私有入口按真机语义（期望来自驱动反汇编，见 t_nvn_nvx.c 头注释）。
$(BUILD)/tests/t_nvn_nvx: graphics/nvn/tests/t_nvn_nvx.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn_nvx.h graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/nvn_drv_names.txt $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_nvx.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_nvx
native-test-nvn_nvx: $(BUILD)/tests/t_nvn_nvx
	timeout 60 $(BUILD)/tests/t_nvn_nvx
TEST_TARGETS += native-test-nvn_nvx
endif
