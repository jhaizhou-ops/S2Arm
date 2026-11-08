# native-test-nvn_glsync：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_glsync
ifeq ($(shell uname -s),Darwin)
# NVN ⇄ GL 同步对象（跨两条 Metal 队列真等）、nvnDeviceWaitForError、nvnInstallGlobalDebugCallback；Metal 4 / Metal 3、编码线程开关各跑一遍
$(BUILD)/tests/t_nvn_glsync: graphics/nvn/tests/t_nvn_glsync.m graphics/nvn/gfx/nvn/nvn_protos.h graphics/nvn/gfx/nvn/include/nvn.h $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -fobjc-arc $(NATIVE_INC) -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include \
	  -o $@ graphics/nvn/tests/t_nvn_glsync.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_glsync
native-test-nvn_glsync: $(BUILD)/tests/t_nvn_glsync
	$(BUILD)/tests/t_nvn_glsync
	NXGAL_BE=mtl3 $(BUILD)/tests/t_nvn_glsync
	DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_glsync
	NXGAL_BE=mtl3 DM_NVN_ENC_THREAD=1 $(BUILD)/tests/t_nvn_glsync
	@echo '✓ t_nvn_glsync：Metal 4 / Metal 3 × 编码线程 0 / 1 四路均通过'
TEST_TARGETS += native-test-nvn_glsync
endif
