# native-test-nvn_ubd_index：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_ubd_index
ifeq ($(shell uname -s),Darwin)
# 遍内常量更新延后表的查找（有序表 + 前缀最大终点）同逐条扫参照、512 条下单次查找低于 400 条指令、512 个不同页不卡死（#895）、真录真画 64 列同命令顺序、无新写的影子原样交回 / 宽屏副本不重拷、宽屏每笔 tex_mtl 次数：直接包含生产 nvn_mtl.m；Metal 4 / Metal 3 × 编码线程关 / 开各跑一遍
$(BUILD)/tests/t_nvn_ubd_index: graphics/nvn/tests/t_nvn_ubd_index.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_ubd_index.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ubd_index
native-test-nvn_ubd_index: $(BUILD)/tests/t_nvn_ubd_index
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_ubd_index
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_ubd_index
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_ubd_index
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_ubd_index
TEST_TARGETS += native-test-nvn_ubd_index
endif
