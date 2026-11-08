# 测试出包线（tests/）构建片段，顶层 Makefile 自动包含。
# 二级目录的片段在这里转包含（顶层只包含一级目录的 */build.mk）。
-include tests/visual/build.mk
.PHONY: services-build-ios-test
services-build-ios-test:
	bash tests/services_build_ios_test.sh
TEST_TARGETS += services-build-ios-test
.PHONY: ios-layer-test
ios-layer-test:
	bash tests/ios_layer_test.sh
TEST_TARGETS += ios-layer-test
# #723 P1：着色器取码失败负缓存（ryujinx 树内的纯逻辑类，单文件编译、不起游戏；失效三条件 / 上限淘汰 / 第二次派发不调解码器）
.PHONY: shader-fault-cache-test
shader-fault-cache-test:
	bash tests/shader_fault_cache_test.sh
TEST_TARGETS += shader-fault-cache-test
# 通用自动玩家（tests/autoplay）：S2A_CS=1 保持宿主与 App 的原有接入；IOS_AUTOPLAY=1 可仅为 iOS 构建加入测试玩家，不触发 Mac C# 库。
# 要渲染器的 s2a_ap_draws / nxgal_screenshot（gfx）与原生层的 s2a_ap_frames / shutdown / log；s2a_ap_audio_mark（声音层）弱引用，没登记时 MARK 处报红。
# iOS 运行时仍需显式设置 S2A_AUTOPLAY=1，正常点开 App 不自动按键。
ifneq ($(filter 1,$(S2A_CS) $(IOS_AUTOPLAY)),)
AP_LIBS := -framework CoreGraphics -framework ImageIO $(call S2A_WEAK_U,autoplay)   # 放行参数按 tests/autoplay/autoplay.c 的「弱链接[autoplay]」登记生成
HOST_SRCS += tests/autoplay/autoplay.c
HOST_LIBS += $(AP_LIBS)
IOS_LIBS  += $(AP_LIBS)
endif
