# native-test-nvn_rec_cover：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_rec_cover
ifeq ($(shell uname -s),Darwin)
# 延后编码替身齐全：nvn_mtl.m 发给 Metal 4 编码器 / 命令缓冲 / 参数表的消息，DmRecEnc / DmRecCB / DmRecTable 都要有替身（iOS 缺省开编码线程，Mac 局拦不住；11-01 族 36 模板参考值）
# 先单独编成 .o：单测读它的选择子名表，只看包含了 nvn_mtl.m 的这一个编译单元
$(BUILD)/tests/t_nvn_rec_cover.o: graphics/nvn/tests/t_nvn_rec_cover.m $(NVN_MTL_DEPS) graphics/nvn/gfx/nvn/nvn_rec.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -c -o $@ graphics/nvn/tests/t_nvn_rec_cover.m
$(BUILD)/tests/t_nvn_rec_cover: $(BUILD)/tests/t_nvn_rec_cover.o $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) -fobjc-arc -o $@ $(BUILD)/tests/t_nvn_rec_cover.o $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_rec_cover
native-test-nvn_rec_cover: $(BUILD)/tests/t_nvn_rec_cover
	$(BUILD)/tests/t_nvn_rec_cover $(BUILD)/tests/t_nvn_rec_cover.o
TEST_TARGETS += native-test-nvn_rec_cover
endif
