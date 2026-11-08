# 帧率能耗线（graphics/）构建片段：被顶层 Makefile 包含。
# 写跟踪进宿主；Metal 渲染器有自己的 Makefile（libnxgal + SPIRV-Cross + 离线着色器库），这里只挂单测。
HOST_SRCS += graphics/track/track.c graphics/track/glue.c
# 链 C#（S2A_CS=1）时渲染器一起静态链进宿主：NxGal 的 nxgal_* 直接调用（DirectPInvoke nxgal），s2a_ap_draws 给自动玩家
ifeq ($(S2A_CS),1)
NXGAL_A := build/gal/mac/libnxgal.a
HOST_LIBS += $(NXGAL_A) -framework Metal -framework Foundation -framework QuartzCore -framework CoreGraphics -lc++
$(BUILD)/s2arm-host: $(NXGAL_A)
# 真实文件目标 + FORCE：每次都进子 make 判依赖，库没变就不重链宿主（.PHONY 会每次重链，同树并行起局互删产物）
$(NXGAL_A): FORCE
	$(MAKE) -C graphics/metal mac
# 直连图形层（graphics/nvn：NVN→Metal，双轨直连模式用；docs/设计_直连架构.md）同样静态链进宿主，只在图形模式 = 直连时被调到
NVN_A := build/nvn/mac/libnvn.a
# VideoToolbox / CoreMedia / CoreVideo：Switch 2 视频解码接管的 AV1 硬件解码（graphics/nvn/gfx/nvn/nvn2_codec.c）
HOST_LIBS += $(NVN_A) -framework ImageIO -framework UniformTypeIdentifiers -framework VideoToolbox -framework CoreMedia -framework CoreVideo
$(BUILD)/s2arm-host: $(NVN_A)
$(NVN_A): FORCE
	$(MAKE) -C graphics/nvn mac
# GL 层运行时兜底的 GLSL 翻译 + glslang（graphics/nvn/Makefile libglx：库里没有的 GLSL 首遇现编；SPIRV-Cross 用上面 libnxgal 那份）
GLX_A := build/nvn/mac/libglx.a
HOST_LIBS += $(GLX_A)
$(BUILD)/s2arm-host: $(GLX_A)
$(GLX_A): FORCE
	$(MAKE) -C graphics/nvn glx-mac
endif

# iOS App（runtime/build.mk 的 make ios）：渲染器 iOS 静态库（gal_*.m + SPIRV-Cross，iOS 首遇现编要它）与依赖框架；
# C# 的 NativeAOT 镜像（服务层 + Ryujinx + NxGal + 渲染循环）只有一份，由 services/build.mk 加，这里不重复。写跟踪 C 源码已随 HOST_SRCS 进 IOS_SRCS
NXGAL_IOS_A := build/gal/ios/libnxgal.a
IOS_LIBS += $(NXGAL_IOS_A) -framework Metal -framework QuartzCore -lc++
ios: $(NXGAL_IOS_A)
$(NXGAL_IOS_A): FORCE
	$(MAKE) -C graphics/metal ios
# 直连图形层 iOS 静态库（graphics/nvn）
NVN_IOS_A := build/nvn/ios/libnvn.a
IOS_LIBS += $(NVN_IOS_A) -framework ImageIO -framework UniformTypeIdentifiers -framework VideoToolbox -framework CoreMedia -framework CoreVideo
ios: $(NVN_IOS_A)
$(NVN_IOS_A): FORCE
	$(MAKE) -C graphics/nvn ios
GLX_IOS_A := build/nvn/ios/libglx.a
IOS_LIBS += $(GLX_IOS_A)
ios: $(GLX_IOS_A)
$(GLX_IOS_A): FORCE
	$(MAKE) -C graphics/nvn glx-ios

.PHONY: gfx-test-track gfx-test-metal FORCE
FORCE:
gfx-test-track:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -o $(BUILD)/tests/t_track graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	$(BUILD)/tests/t_track
	@# ㉚ 反证：同一用例编旧逻辑（缺页处理两次读记账值），必须在竞态下崩（测试信号处理退出 4）
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -DS2A_TRACK_TEST_OLD -o $(BUILD)/tests/t_track_old graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	@S2A_T_TRACK_ONLY30=1 $(BUILD)/tests/t_track_old > /dev/null 2>&1; rc=$$?; if [ $$rc = 4 ]; then echo "㉚ 反证：旧逻辑在竞态下读缺页没接住（退出 4）✓"; else echo "✗ ㉚ 反证不成立：旧逻辑退出 $$rc（应为 4）"; exit 1; fi
	@# 11-06 宿主写一个字不撕裂（瓦力欧混响读量 896）：反证用旧 memcpy 写法，4 字节必须读到半截值（单测 1 项红）
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -DS2A_TRACK_TEST_OLD_STORE -o $(BUILD)/tests/t_track_tear_old graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	@S2A_T_TRACK_ONLY_TEAR=1 $(BUILD)/tests/t_track_tear_old > $(BUILD)/tests/t_track_tear_old.log 2>&1; rc=$$?; if [ $$rc = 1 ] && grep -Fq 't_track 撕裂：3 项，失败 1' $(BUILD)/tests/t_track_tear_old.log; then echo "撕裂反证：旧 memcpy 写法 4 字节读到半截值 ✓"; else cat $(BUILD)/tests/t_track_tear_old.log; echo "✗ 撕裂反证不成立"; exit 1; fi
	@# #923：另编64项小环，复现溢出后的完整通知/重入环，生产版本仍65536项。
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -DRING=64 -o $(BUILD)/tests/t_track_overflow graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	S2A_T_TRACK_ONLY_OVERFLOW=1 $(BUILD)/tests/t_track_overflow
	@# #923 独立热路径后续：生产唯一路径；旧协议只在编译期反证中存在。
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -DRING=64 -o $(BUILD)/tests/t_track_ring_protocol graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	S2A_T_TRACK_ONLY_RING_PROTOCOL=1 $(BUILD)/tests/t_track_ring_protocol
	$(CC) $(CFLAGS) -O2 -Iruntime/include -DS2A_TRACK_TEST -DS2A_TRACK_TEST_OLD_RING -DRING=64 -o $(BUILD)/tests/t_track_ring_protocol_old graphics/track/tests/t_track.c graphics/track/track.c runtime/src/emul_ld.c runtime/src/emul_st.c -lpthread
	@S2A_T_TRACK_ONLY_RING_PROTOCOL=1 $(BUILD)/tests/t_track_ring_protocol_old > $(BUILD)/tests/t_track_ring_legacy.log 2>&1; rc=$$?; if [ $$rc = 1 ] && grep -Fq 't_track ring protocol：5 项，失败 1' $(BUILD)/tests/t_track_ring_legacy.log && grep 'ticket page can enqueue after consumption' $(BUILD)/tests/t_track_ring_legacy.log | grep -q '✗'; then echo "环发布反证：旧协议同页后续写漏报（5项1红）✓"; else cat $(BUILD)/tests/t_track_ring_legacy.log; echo "✗ 环发布负对照不成立"; exit 1; fi
gfx-test-metal:
	$(MAKE) -C graphics/metal test
TEST_TARGETS += gfx-test-track gfx-test-metal

.PHONY: gfx-test-frame-pacing
gfx-test-frame-pacing:
	bash tests/frame_pacing/test.sh
TEST_TARGETS += gfx-test-frame-pacing
