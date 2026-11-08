# Vulkan 层核心命令补齐（#271）的真 GPU 回归。在仓库根跑：make -f tests/vk_core/Makefile vk-core-test
# 只链直连层 libnvn.a + 宿主替身（graphics/nvn/tests/host_stubs.h），不链宿主、不发布宽屏 NativeAOT。
# 着色器：同目录 GLSL → glslangValidator 出 SPIR-V → 出包工具 vk_shaders.py 出 Metal 库（要 Homebrew glslang / spirv-cross）；
#   rt.frag 故意不进库（放 spv_rt/），测设备现编（graphics/metal/gal_vkx.m + 本仓 SPIRV-Cross，乙）
ROOT := $(abspath .)
# Xcode 按用户机器（10-25，不写死版本）：指定 S2A_DEVELOPER_DIR > 环境里的 DEVELOPER_DIR（tools/toolchain.sh 解析后导出）> xcode-select；
#   先在 include 之前记下环境值——toolchain.env 里那行不当缺省（make 里文件内赋值会盖过环境变量）。赋值行不带行尾注释：注释前的空格会进值
_S2A_ENV_DD := $(DEVELOPER_DIR)
include tools/toolchain.env
DEVELOPER_DIR := $(or $(S2A_DEVELOPER_DIR),$(_S2A_ENV_DD),$(shell xcode-select -p 2>/dev/null))
export DEVELOPER_DIR
.DELETE_ON_ERROR:
VKC_DIR := build/tests/vk_core
NVN_OUT := $(ROOT)/build/nvn
VKC_LIB := $(NVN_OUT)/mac/libnvn.a
NVN_TEST_WEAK := $(shell python3 $(ROOT)/tools/weak_link_decl.py flags nvntest)   # libnvn 引用的宿主符号放行参数，按源码「弱链接[nvntest]」登记生成
VKC_FLAGS := -O1 -g -Wall -Wno-unused-function -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET) -Iruntime/include -Igraphics/nvn/tests -I$(NVN_OUT)/tests -Igraphics/nvn/third_party/vulkan-headers/include
VKC_SHADERS := tri.vert color.frag input.frag fill.comp lod.frag lodx.frag atomic.comp vin.vert vin.frag ubo0.frag ubo1.frag

$(VKC_LIB) $(NVN_OUT)/tests/widen_stubs.inc: FORCE
	$(MAKE) -s -C graphics/nvn mac widen-stubs
$(VKC_DIR)/stubs.o: tests/vk_indirect_count/stubs.m graphics/nvn/tests/host_stubs.h $(NVN_OUT)/tests/widen_stubs.inc
	@mkdir -p $(dir $@)
	clang -std=gnu11 -fobjc-arc $(VKC_FLAGS) -c $< -o $@
SPVC_LIB := $(ROOT)/build/gal/libspvc.a
$(SPVC_LIB): FORCE
	$(MAKE) -s -C graphics/metal $(SPVC_LIB)
$(VKC_DIR)/vkx.o: graphics/metal/gal_vkx.m
	@mkdir -p $(dir $@)
	clang -std=gnu11 -fobjc-arc $(VKC_FLAGS) -Igraphics/third_party/spirv_cross -c $< -o $@
$(VKC_DIR)/test: tests/vk_core/test.c tests/vk_core/Makefile $(VKC_DIR)/stubs.o $(VKC_DIR)/vkx.o $(VKC_LIB) $(SPVC_LIB)
	clang -std=gnu11 $(VKC_FLAGS) -o $@ $< $(VKC_DIR)/stubs.o $(VKC_DIR)/vkx.o $(VKC_LIB) $(SPVC_LIB) \
	  -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -lc++ $(NVN_TEST_WEAK)
$(VKC_DIR)/spv_rt/rt.frag.spv: tests/vk_core/rt.frag
	@mkdir -p $(dir $@)
	glslangValidator -V --target-env vulkan1.1 -o $@ $< > /dev/null
$(VKC_DIR)/spv_rt/rtp.%.spv: tests/vk_core/rtp.%
	@mkdir -p $(dir $@)
	glslangValidator -V --target-env vulkan1.1 -o $@ $< > /dev/null
$(VKC_DIR)/spv/%.spv: tests/vk_core/%
	@mkdir -p $(dir $@)
	glslangValidator -V --target-env vulkan1.1 -o $@ $< > /dev/null
$(VKC_DIR)/shaders/vk/vk_shaders.metallib: $(addprefix $(VKC_DIR)/spv/,$(addsuffix .spv,$(VKC_SHADERS))) translator/vk_shaders.py
	python3 translator/vk_shaders.py $(VKC_DIR)/spv $(VKC_DIR)/shaders > /dev/null
# ⑳ 直连就绪判定的四个游戏数据夹具（<游戏数据>/shaders/direct/vk/）：只有表头（出包工具 --header-only）/ 表头口径号减 1 / 离线库原样 / 有行的表没有库
VKC_GD := $(abspath $(VKC_DIR)/gd)
$(VKC_GD)/.stamp: $(VKC_DIR)/shaders/vk/vk_shaders.metallib translator/vk_shaders.py
	rm -rf $(VKC_GD) && mkdir -p $(VKC_GD)/lib/shaders/direct/vk $(VKC_GD)/nolib/shaders/direct/vk $(VKC_GD)/abi/shaders/direct/vk
	python3 translator/vk_shaders.py --header-only $(VKC_GD)/hdr/shaders/direct > /dev/null
	cp $(VKC_DIR)/shaders/vk/vk_shaders.metallib $(VKC_DIR)/shaders/vk/vk_shaders.tsv $(VKC_GD)/lib/shaders/direct/vk/
	cp $(VKC_DIR)/shaders/vk/vk_shaders.tsv $(VKC_GD)/nolib/shaders/direct/vk/
	awk 'NR == 1 { $$NF = $$NF - 1 } { print }' $(VKC_GD)/hdr/shaders/direct/vk/vk_shaders.tsv > $(VKC_GD)/abi/shaders/direct/vk/vk_shaders.tsv
	touch $@
VKC_GD_ENV := T_GD_HDR=$(VKC_GD)/hdr T_GD_ABI=$(VKC_GD)/abi T_GD_LIB=$(VKC_GD)/lib T_GD_NOLIB=$(VKC_GD)/nolib
.PHONY: vk-core-test FORCE
vk-core-test: $(VKC_DIR)/test $(VKC_DIR)/shaders/vk/vk_shaders.metallib $(VKC_DIR)/spv_rt/rt.frag.spv $(addprefix $(VKC_DIR)/spv_rt/rtp.,vert.spv frag.spv comp.spv) $(VKC_GD)/.stamp
	rm -rf $(VKC_DIR)/rtcache
	DM_MSL_DIR=$(abspath $(VKC_DIR)/shaders) T_VK_SPV=$(abspath $(VKC_DIR)/spv) T_VK_SPV_RT=$(abspath $(VKC_DIR)/spv_rt) DM_MSL_FALLBACK=$(abspath $(VKC_DIR)/rtcache) $(VKC_GD_ENV) \
	  timeout 120 $(VKC_DIR)/test
	DM_MSL_DIR=$(abspath $(VKC_DIR)/shaders) T_VK_SPV=$(abspath $(VKC_DIR)/spv) T_VK_SPV_RT=$(abspath $(VKC_DIR)/spv_rt) DM_MSL_FALLBACK=$(abspath $(VKC_DIR)/rtcache) $(VKC_GD_ENV) T_VK_RT_WARM=1 \
	  timeout 120 $(VKC_DIR)/test
	# ㉑ 管线建在它的着色器现编完成之前（11-05 Minecraft 离线库 0 支）：单独进程、单独持久化目录（不动 ⑬ 的文件计数），每次冷起
	rm -rf $(VKC_DIR)/rtcache_pend
	DM_MSL_DIR=$(abspath $(VKC_DIR)/shaders) T_VK_SPV=$(abspath $(VKC_DIR)/spv) T_VK_SPV_RT=$(abspath $(VKC_DIR)/spv_rt) DM_MSL_FALLBACK=$(abspath $(VKC_DIR)/rtcache_pend) T_VK_RT_PEND=1 \
	  timeout 120 $(VKC_DIR)/test
	# #800：本机 GPU 采样器偏置不生效那一路（M3 等）在本机上走一遍：S2A_SAMP_EMU=1 → 带偏置的采样器不设偏置、绘制用设备上现出的偏置模拟版（⑭ 同一组期望）
	DM_MSL_DIR=$(abspath $(VKC_DIR)/shaders) T_VK_SPV=$(abspath $(VKC_DIR)/spv) T_VK_SPV_RT=$(abspath $(VKC_DIR)/spv_rt) DM_MSL_FALLBACK=$(abspath $(VKC_DIR)/rtcache) $(VKC_GD_ENV) T_VK_RT_WARM=1 S2A_SAMP_EMU=1 \
	  timeout 120 $(VKC_DIR)/test
