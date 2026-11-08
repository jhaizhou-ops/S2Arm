# 公开 API 录制 → 生产 draw_idx_rec；无需提交 GPU 绘制。
NATIVE_TEST_OWN += nvn_draw_record
ifeq ($(shell uname -s),Darwin)
$(BUILD)/tests/t_nvn_draw_record: graphics/nvn/tests/t_nvn_draw_record.c graphics/nvn/gfx/nvn/nvn_obj.h graphics/nvn/gfx/nvn/nvn2_cmd.h graphics/nvn/gfx/nvn/nvn_protos.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_draw_record.c $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_draw_record
native-test-nvn_draw_record: $(BUILD)/tests/t_nvn_draw_record
	timeout 60 $(BUILD)/tests/t_nvn_draw_record
TEST_TARGETS += native-test-nvn_draw_record
endif
