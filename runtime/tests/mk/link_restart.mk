# 进程内重启后显示链接拍号 / 深度约定计数复位（生产 nvn_mtl.m 源码 + 真 Metal 设备，graphics/nvn/tests/t_link_restart.m）
NATIVE_TEST_OWN += link_restart
ifeq ($(shell uname -s),Darwin)
LINK_RESTART_SOURCE ?= graphics/nvn/gfx/nvn/nvn_mtl.m
LINK_RESTART_BINARY ?= $(BUILD)/tests/t_nvn_link_restart
$(LINK_RESTART_BINARY): graphics/nvn/tests/t_link_restart.m $(LINK_RESTART_SOURCE) $(NVN_MTL_DEPS) $(dir $(LINK_RESTART_SOURCE))nvn_session.inc $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -DLINK_RESTART_SOURCE='"$(abspath $(LINK_RESTART_SOURCE))"' \
	  -o $@ graphics/nvn/tests/t_link_restart.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-link_restart
native-test-link_restart: $(LINK_RESTART_BINARY)
	$(LINK_RESTART_BINARY)
TEST_TARGETS += native-test-link_restart
endif
