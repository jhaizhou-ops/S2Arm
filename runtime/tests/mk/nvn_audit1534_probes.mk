# native-test-nvn_audit1534_probes：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_audit1534_probes
ifeq ($(shell uname -s),Darwin)
# 审计 #1534 被动采样（P1-65 界长表 / P1-23 等待 / P1-20 纹理类型）：命中计 1、正常计 0
$(BUILD)/tests/t_nvn_audit1534_probes: graphics/nvn/tests/t_nvn_audit1534_probes.m graphics/nvn/gfx/nvn/nvn_mtl.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_audit1534_probes.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_audit1534_probes
native-test-nvn_audit1534_probes: $(BUILD)/tests/t_nvn_audit1534_probes
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_audit1534_probes
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_audit1534_probes
TEST_TARGETS += native-test-nvn_audit1534_probes
endif
