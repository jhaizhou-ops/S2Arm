# native-test-nvn_fmt_mtl_core：D7 B——Metal 映射表是纯 C，可在 Linux 上单独编译运行。
NATIVE_TEST_OWN += nvn_fmt_mtl_core
NVN_FMT_MTL_DIR := graphics/nvn/gfx/tex
NVN_FMT_INFO_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_fmt_mtl_core
native-test-nvn_fmt_mtl_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -I$(NVN_FMT_MTL_DIR) -I$(NVN_FMT_INFO_DIR) \
	  -o $(BUILD)/tests/t_nvn_fmt_mtl_core runtime/tests/t_nvn_fmt_mtl_core.c $(NVN_FMT_MTL_DIR)/nvn_fmt_mtl.c $(NVN_FMT_INFO_DIR)/nvn_fmt_expand.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_FMT_MTL_DIR)/nvn_fmt_mtl.c $(NVN_FMT_MTL_DIR)/nvn_fmt_mtl.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_fmt_mtl 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_fmt_mtl.c/h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_fmt_mtl_core
TEST_TARGETS += native-test-nvn_fmt_mtl_core
