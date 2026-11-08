# native-test-nvn_abba：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
# 直连纹理释放在「虚拟核 / g_rmu」上的锁序（botw 出图停 1500 帧的 ABBA）：只链 libnvn.a + 宿主替身，不起宿主、不要 GPU。
# 本测自带「核」替身（host_stubs.h 里那两个入口由 S2A_TEST_OWN_CORE 让出），并且把 nvn_mtl.m 编进测试 TU：
#   要直接拿产品的 static 锁 g_rmu 当「另一条线程正持着它」，这是唯一能复现 ABBA 的地方。
NATIVE_TEST_OWN += nvn_abba
ifeq ($(shell uname -s),Darwin)
# 宿主替身的宽屏入口按 s2a_widen.h 生成（与 graphics/nvn/Makefile 的 widen-stubs 同一份产物）
NVN_ABBA_STUBS := $(NVN_TEST_DIR)/nvn/tests/widen_stubs.inc
$(NVN_ABBA_STUBS):
	$(MAKE) -s -C graphics/nvn OUT=$(abspath $(NVN_TEST_DIR)/nvn) widen-stubs
$(BUILD)/tests/t_nvn_abba: graphics/nvn/tests/t_nvn_abba.m $(NVN_MTL_DEPS) graphics/nvn/tests/host_stubs.h $(NVN_ABBA_STUBS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Iruntime/src -Iplatforms -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -Igraphics/nvn/tests -I$(NVN_TEST_DIR)/nvn/tests \
	  -o $@ graphics/nvn/tests/t_nvn_abba.m $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_abba
native-test-nvn_abba: $(BUILD)/tests/t_nvn_abba
	timeout 60 $(BUILD)/tests/t_nvn_abba finalize
	timeout 60 $(BUILD)/tests/t_nvn_abba reinit
	timeout 60 $(BUILD)/tests/t_nvn_abba old
TEST_TARGETS += native-test-nvn_abba
endif
