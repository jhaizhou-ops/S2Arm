# native-test-nvn_pace_core：D7 第七片——上屏节拍器是纯函数（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_pace_core
NVN_PACE_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_pace_core
native-test-nvn_pace_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_PACE_CORE_DIR) -o $(BUILD)/tests/t_nvn_pace_core runtime/tests/t_nvn_pace_core.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_PACE_CORE_DIR)/nvn_pace.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_pace.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_pace.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_pace_core
TEST_TARGETS += native-test-nvn_pace_core
