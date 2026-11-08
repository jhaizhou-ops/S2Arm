# Vulkan 间接计数真 GPU 回归。在仓库根跑：make -f tests/vk_indirect_count/Makefile vk-indirect-count-test
# 只链直连层 libnvn.a（graphics/nvn/Makefile 的产物）+ 宿主替身（graphics/nvn/tests/host_stubs.h，与 t_nvn_m3 共用），不链宿主、不发布宽屏 NativeAOT。
# 着色器：合成 GLSL → glslangValidator 出 SPIR-V → 出包工具 vk_shaders.py 出 Metal 库（要 Homebrew glslang / spirv-cross）
ROOT := $(abspath .)
# Xcode 按用户机器（10-25，不写死版本）：指定 S2A_DEVELOPER_DIR > 环境里的 DEVELOPER_DIR（tools/toolchain.sh 解析后导出）> xcode-select；
#   先在 include 之前记下环境值——toolchain.env 里那行不当缺省（make 里文件内赋值会盖过环境变量）。赋值行不带行尾注释：注释前的空格会进值
_S2A_ENV_DD := $(DEVELOPER_DIR)
include tools/toolchain.env
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR
.DELETE_ON_ERROR:
VK_TEST_DIR := build/tests/vk_indirect_count
NVN_OUT := $(ROOT)/build/nvn
VK_TEST_LIB := $(NVN_OUT)/mac/libnvn.a
NVN_TEST_WEAK := $(shell python3 $(ROOT)/tools/weak_link_decl.py flags nvntest)
VK_TEST_FLAGS := -O1 -g -Wall -Wno-unused-function -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Iruntime/include -Igraphics/nvn/tests -I$(NVN_OUT)/tests -Igraphics/nvn/third_party/vulkan-headers/include

$(VK_TEST_LIB) $(NVN_OUT)/tests/widen_stubs.inc: FORCE
	$(MAKE) -s -C graphics/nvn mac widen-stubs
$(VK_TEST_DIR)/stubs.o: tests/vk_indirect_count/stubs.m graphics/nvn/tests/host_stubs.h $(NVN_OUT)/tests/widen_stubs.inc
	@mkdir -p $(dir $@)
	clang -std=gnu11 -fobjc-arc $(VK_TEST_FLAGS) -c $< -o $@
$(VK_TEST_DIR)/test: tests/vk_indirect_count/test.c tests/vk_indirect_count/Makefile $(VK_TEST_DIR)/stubs.o $(VK_TEST_LIB)
	clang -std=gnu11 $(VK_TEST_FLAGS) -o $@ $< $(VK_TEST_DIR)/stubs.o $(VK_TEST_LIB) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++ $(NVN_TEST_WEAK)
$(VK_TEST_DIR)/spv/tri.vert.spv: tests/vk_indirect_count/tri.vert
	@mkdir -p $(dir $@)
	glslangValidator -V --target-env vulkan1.1 -o $@ $<
$(VK_TEST_DIR)/spv/tri.frag.spv: tests/vk_indirect_count/tri.frag
	@mkdir -p $(dir $@)
	glslangValidator -V --target-env vulkan1.1 -o $@ $<
$(VK_TEST_DIR)/shaders/vk/vk_shaders.metallib: $(VK_TEST_DIR)/spv/tri.vert.spv $(VK_TEST_DIR)/spv/tri.frag.spv translator/vk_shaders.py
	python3 translator/vk_shaders.py $(VK_TEST_DIR)/spv $(VK_TEST_DIR)/shaders
.PHONY: vk-indirect-count-test FORCE
vk-indirect-count-test: $(VK_TEST_DIR)/test $(VK_TEST_DIR)/shaders/vk/vk_shaders.metallib
	DM_MSL_DIR=$(abspath $(VK_TEST_DIR)/shaders) T_VK_SPV=$(abspath $(VK_TEST_DIR)/spv) timeout 120 $(VK_TEST_DIR)/test
