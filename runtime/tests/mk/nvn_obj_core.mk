# native-test-nvn_obj_core：D7 第六片——命令记录解码 / 同步发布是纯 C（header-only），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_obj_core
NVN_OBJ_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_obj_core
native-test-nvn_obj_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function -I$(NVN_OBJ_CORE_DIR) -I$(NVN_OBJ_CORE_DIR)/include -o $(BUILD)/tests/t_nvn_obj_core runtime/tests/t_nvn_obj_core.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_OBJ_CORE_DIR)/nvn_obj.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_obj.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_obj.h 无 Metal / Vulkan / Foundation include"
	$(BUILD)/tests/t_nvn_obj_core
TEST_TARGETS += native-test-nvn_obj_core
