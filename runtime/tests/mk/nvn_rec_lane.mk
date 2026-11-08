# native-test-nvn_rec_lane：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rec_lane
ifeq ($(shell uname -s),Darwin)
# 录制分道：道 1 / 2 接在主流后执行（几何绘制段，金刚 11-06）
$(BUILD)/tests/t_nvn_rec_lane: graphics/nvn/tests/t_nvn_rec_lane.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_rec_lane.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rec_lane
native-test-nvn_rec_lane: $(BUILD)/tests/t_nvn_rec_lane
	$(BUILD)/tests/t_nvn_rec_lane
TEST_TARGETS += native-test-nvn_rec_lane
endif
