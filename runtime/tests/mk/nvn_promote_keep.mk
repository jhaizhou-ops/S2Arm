# native-test-nvn_promote_keep：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来）
NATIVE_TEST_OWN += nvn_promote_keep
ifeq ($(shell uname -s),Darwin)
# GPU 贴图转随包贴图时留住 GPU 写过的级（巫师3 远景植被品红，11-04）：完整 bootstrap、录制、Metal 3/4 回放与提交内拷出。
$(BUILD)/tests/t_nvn_promote_keep: graphics/nvn/tests/t_nvn_promote_keep.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_promote_keep.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_promote_keep
native-test-nvn_promote_keep: $(BUILD)/tests/t_nvn_promote_keep
	NXGAL_BE=mtl4 $(BUILD)/tests/t_nvn_promote_keep
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_promote_keep
TEST_TARGETS += native-test-nvn_promote_keep
endif
