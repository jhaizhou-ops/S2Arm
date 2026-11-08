# native-test-nvn_builtin_core：D7 第八片——曲面细分辅助是纯 C（header-only，C 编译下无 NSString 分支）。
# 头文件按正式脚本生成 gal_tess_msl.h（与 graphics/nvn/Makefile 同一份），Linux / Mac 都能单独编译运行。
NATIVE_TEST_OWN += nvn_builtin_core
NVN_BUILTIN_CORE_DIR := graphics/nvn/gfx/nvn
NVN_TESS_GEN := $(BUILD)/tests/gen/gal_tess_msl.h
.PHONY: native-test-nvn_builtin_core
native-test-nvn_builtin_core: $(NVN_TESS_GEN)
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -Wno-unused-function \
	  -I$(NVN_BUILTIN_CORE_DIR) -I$(NVN_BUILTIN_CORE_DIR)/include -I$(BUILD)/tests/gen \
	  -o $(BUILD)/tests/t_nvn_builtin_core runtime/tests/t_nvn_builtin_core.c
	@bad=$$(grep -nE '^[[:space:]]*#(include|import)[[:space:]]*<(Metal|Foundation|QuartzCore|vulkan)' $(NVN_BUILTIN_CORE_DIR)/nvn_builtin.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_builtin.h 直接 include 了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_builtin.h 无 Metal / Vulkan / Foundation include（NSString 只在 __OBJC__ 分支）"
	$(BUILD)/tests/t_nvn_builtin_core

$(NVN_TESS_GEN): graphics/metal/gal_tess_d3d.h graphics/metal/tools/embed_msl.py
	@mkdir -p $(dir $@)
	python3 graphics/metal/tools/embed_msl.py graphics/metal/gal_tess_d3d.h k_nvn_tess_core $@
TEST_TARGETS += native-test-nvn_builtin_core
