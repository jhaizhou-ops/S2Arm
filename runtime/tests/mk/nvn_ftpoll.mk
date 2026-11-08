# native-test-nvn_ftpoll：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_ftpoll
ifeq ($(shell uname -s),Darwin)
# 脏页轮询按 GPU 写账发布 CPU 后写的贴图（hle_nvn.c nvn_ft_poll，nvn_mtl.m nvn_be_tex_gpu_owned）；编码线程 0 / 1 各跑一遍
$(BUILD)/tests/t_nvn_ftpoll: graphics/nvn/tests/t_nvn_ftpoll.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_ftpoll.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_ftpoll
native-test-nvn_ftpoll: $(BUILD)/tests/t_nvn_ftpoll
	DM_NVN_ENC_THREAD=0 $(BUILD)/tests/t_nvn_ftpoll
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_ftpoll
	@echo '✓ t_nvn_ftpoll：编码线程 0 / 1 两种模式均通过'
TEST_TARGETS += native-test-nvn_ftpoll
endif
