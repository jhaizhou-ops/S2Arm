# native-test-nvn_fstep_core：D7 第四片——帧步进状态机是纯函数（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_fstep_core
NVN_FSTEP_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_fstep_core
native-test-nvn_fstep_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_FSTEP_CORE_DIR) -o $(BUILD)/tests/t_nvn_fstep_core runtime/tests/t_nvn_fstep_core.c -lm
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_FSTEP_CORE_DIR)/nvn_fstep.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_fstep.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_fstep.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_fstep_core
TEST_TARGETS += native-test-nvn_fstep_core
