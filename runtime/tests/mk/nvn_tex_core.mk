# native-test-nvn_tex_core：D7 第一片——纹理布局是纯 C，能在 Linux / Mac 上单独编译运行，不链 Metal / Foundation。
# 与 runtime/tests/mk/nvn_tex.mk 的 Mac Texture 组（#270 N12）并存，两者产物名不同。
NATIVE_TEST_OWN += nvn_tex_core
NVN_TEX_CORE_DIR := graphics/nvn/gfx/nvn
.PHONY: native-test-nvn_tex_core
native-test-nvn_tex_core:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -std=c11 -Werror -I$(NVN_TEX_CORE_DIR) -o $(BUILD)/tests/t_nvn_tex_core runtime/tests/t_nvn_tex_core.c $(NVN_TEX_CORE_DIR)/nvn_tex.c
	@bad=$$(grep -nE '#(include|import) *<(Metal|Foundation|QuartzCore|vulkan)|(^|[^A-Za-z_])(MTL[A-Za-z0-9_]*|Vk[A-Z][A-Za-z0-9]*|NSObject)([^A-Za-z_]|$$)' $(NVN_TEX_CORE_DIR)/nvn_tex.c $(NVN_TEX_CORE_DIR)/nvn_tex.h || true); \
	  if [ -n "$$bad" ]; then echo "【红】nvn_tex 依赖了图形 API / Foundation：$$bad"; exit 1; fi; \
	  echo "依赖扫描：nvn_tex.c/h 无 Metal / Vulkan / Foundation"
	$(BUILD)/tests/t_nvn_tex_core
TEST_TARGETS += native-test-nvn_tex_core
