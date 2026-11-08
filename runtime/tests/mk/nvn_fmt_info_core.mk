# native-test-nvn_fmt_info_core：D7 B——中立格式信息表。生成头与 nvn.h 同步检查，再与 nvn_tex 的 bpb 交叉核对。
NATIVE_TEST_OWN += nvn_fmt_info_core
NVN_FMTINFO_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_fmt_info_core
native-test-nvn_fmt_info_core:
	@mkdir -p $(BUILD)/tests
	python3 graphics/nvn/tools/gen_nvn_fmt_info.py --check
	$(CC) $(CFLAGS) -std=c11 -Werror -I$(NVN_FMTINFO_DIR) -o $(BUILD)/tests/t_nvn_fmt_info_core runtime/tests/t_nvn_fmt_info_core.c $(NVN_FMTINFO_DIR)/nvn_tex.c $(NVN_FMTINFO_DIR)/nvn_fmt_expand.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_FMTINFO_DIR)/nvn_fmt_info.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_fmt_info.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_fmt_info.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_fmt_info_core
TEST_TARGETS += native-test-nvn_fmt_info_core
