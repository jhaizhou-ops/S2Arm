# native-test-nvn_pso_batch：本单测的构建规则（runtime/build.mk 末尾按 runtime/tests/mk/*.mk 收进来；新单测只新增一个分片，不改 build.mk）
NATIVE_TEST_OWN += nvn_pso_batch
ifeq ($(shell uname -s),Darwin)
# 管线归档批量写回：70 条写成 3 个批文件、按键取回
$(BUILD)/tests/t_nvn_pso_batch: graphics/nvn/tests/t_nvn_pso_batch.m $(NVN_MTL_DEPS) $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN)
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $@ graphics/nvn/tests/t_nvn_pso_batch.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics \
	  -framework ImageIO -framework UniformTypeIdentifiers -lc++
.PHONY: native-test-nvn_pso_batch
native-test-nvn_pso_batch: $(BUILD)/tests/t_nvn_pso_batch
	$(BUILD)/tests/t_nvn_pso_batch
	@# 反证：一条一个文件（-DPAR_BATCH=1）→ 批文件 70 个，① 必须不符
	$(CC) $(CFLAGS) -std=gnu11 -fobjc-arc -Wno-unused-function -Wno-unguarded-availability-new -Wno-unguarded-availability -DPAR_BATCH=1 -I$(abspath $(NVN_TEST_DIR)/nvn/gen) \
	  $(NATIVE_INC) -Igraphics/nvn/host -Igraphics/nvn/gfx/nvn -Igraphics/nvn/gfx/nvn/include -Igraphics/nvn/third_party/vulkan-headers/include \
	  -o $(BUILD)/tests/t_nvn_pso_batch_old graphics/nvn/tests/t_nvn_pso_batch.m $(NVN_TEST_HOST_OBJS) $(NVN_TEST_LIB) $(NVN_TEST_WIDEN) \
	  -Wl,-rpath,@executable_path/nvn/widen $(NVN_TEST_WEAK) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++
	@$(BUILD)/tests/t_nvn_pso_batch_old > $(BUILD)/tests/t_nvn_pso_batch_old.log 2>&1; rc=$$?; if [ $$rc = 1 ] && grep -q 'FAIL ① 批文件 70 个' $(BUILD)/tests/t_nvn_pso_batch_old.log; then echo "批量写回反证：一条一个文件 → 70 个批文件，① 不符 ✓"; else cat $(BUILD)/tests/t_nvn_pso_batch_old.log; echo "✗ 批量写回反证不成立"; exit 1; fi
TEST_TARGETS += native-test-nvn_pso_batch
endif
