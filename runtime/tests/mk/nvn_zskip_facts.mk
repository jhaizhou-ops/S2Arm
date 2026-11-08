# native-test-nvn_zskip_facts：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_zskip_facts
ifeq ($(shell uname -s),Darwin)
# 零源跳过事实载入（zskip_facts_load）：随包 game.tsv 的 zero_skip 键与 DM_NVN_ZSKIP_FACTS 进事实表
$(BUILD)/tests/t_nvn_zskip_facts: graphics/nvn/tests/t_nvn_zskip_facts.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_zskip_facts.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_zskip_facts
native-test-nvn_zskip_facts: $(BUILD)/tests/t_nvn_zskip_facts
	$(BUILD)/tests/t_nvn_zskip_facts
TEST_TARGETS += native-test-nvn_zskip_facts
endif
