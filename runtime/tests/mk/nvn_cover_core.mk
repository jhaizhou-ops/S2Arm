# native-test-nvn_cover_core：D7 第三片——首绘全覆盖判定是纯函数（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_cover_core
NVN_COVER_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_cover_core
native-test-nvn_cover_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_COVER_CORE_DIR) -o $(BUILD)/tests/t_nvn_cover_core runtime/tests/t_nvn_cover_core.c -lm
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_COVER_CORE_DIR)/nvn_cover.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_cover.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_cover.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_cover_core
TEST_TARGETS += native-test-nvn_cover_core
