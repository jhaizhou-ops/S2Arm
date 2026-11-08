# native-test-nvn_sd_cap：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_sd_cap
ifeq ($(shell uname -s),Darwin)
# 写回预判附件表到上限（审计 #799 F-sd-att-10）：8 个颜色 + 组合深度模板一次 pass 记 10 条；ASan 编译，表写穿即中止；Metal 3/4、TBDR 关/开四路
$(BUILD)/tests/t_nvn_sd_cap: graphics/nvn/tests/t_nvn_sd_cap.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fsanitize=address -fno-omit-frame-pointer -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_sd_cap.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_sd_cap
native-test-nvn_sd_cap: $(BUILD)/tests/t_nvn_sd_cap
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_sd_cap
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_sd_cap
	NXGAL_BE=mtl4 DM_NVN_TBDR=1 $(BUILD)/tests/t_nvn_sd_cap
	NXGAL_BE=mtl3 DM_NVN_TBDR=1 $(BUILD)/tests/t_nvn_sd_cap
TEST_TARGETS += native-test-nvn_sd_cap
endif
