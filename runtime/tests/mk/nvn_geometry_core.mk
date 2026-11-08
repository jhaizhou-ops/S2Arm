# native-test-nvn_geometry_core：D7 第二片——图元装配是纯 C（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_geometry_core
NVN_GEO_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_geometry_core
native-test-nvn_geometry_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_GEO_CORE_DIR) -o $(BUILD)/tests/t_nvn_geometry_core runtime/tests/t_nvn_geometry_core.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_GEO_CORE_DIR)/nvn_geometry.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_geometry.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_geometry.h 无直接的 Metal / Vulkan / Foundation include（MSL 只在字符串里）"
	$(BUILD)/tests/t_nvn_geometry_core
TEST_TARGETS += native-test-nvn_geometry_core
