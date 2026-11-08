# Android single-library native source lists, shared by the production CMake target
# and the source-level link-symbol check (link_symbols.py). One definition, so a
# gate that reads these lists cannot drift from what the build actually compiles.
#
# Paths are relative to android unless a function documents otherwise.
# The mode argument is "diagnostic" or "game"; static_services is "static" when the
# NativeAOT service layer is linked into the same library (S2A_CS_SERVICES=static).

if(NOT COMMAND s2a_android_game_sources)
    include("${CMAKE_CURRENT_LIST_DIR}/Runtime.cmake")
endif()

function(s2a_android_host_sources output)
    set(sources
        runtime/s2a_savecommit.c runtime/capacity_affinity.cpp
        runtime/bridge.cpp runtime/lan_discovery.cpp ../../runtime/src/lan_elect.c runtime/capture_jpeg.cpp runtime/touch_jni.cpp runtime/game_touch.c runtime/window.cpp runtime/presenter.cpp
        runtime/wsi_lease.c runtime/input.c runtime/tsd.c runtime/module.c runtime/selftest.c runtime/selftest_gate.S
        runtime/guest_signal.c runtime/redlog.c runtime/redzone.S runtime/pcm_ring.c runtime/aaudio_sink.c runtime/hostapi.c runtime/screen_metrics.c
        runtime/host_android.c runtime/host_ui.c runtime/host_ui_android.c runtime/host_ui_jni.cpp runtime/plat_android.c
        runtime/direct_vk.c runtime/direct_session.c runtime/direct_choice.c runtime/direct_callback.c runtime/direct_callback.S)
    if(S2A_ANDROID_EXPERIMENTAL_TOUCH)
        list(APPEND sources runtime/touch_input.c)
    endif()
    set(${output} "${sources}" PARENT_SCOPE)
endfunction()

function(s2a_android_diagnostic_sources output)
    # 游戏目标由 Runtime.cmake 提供；诊断目标同样链接真实相位和时钟。
    # 静态服务层（DirectPInvoke）引用 graphics/track 的写跟踪符号，诊断目标也编入同一实现，
    # 不再另写空实现：两种目标的行为一致，只是诊断不跑 guest 内存。
    # 直连核心的页级写跟踪（nvn_dirty → nvn_host_hooks）登记到 direct_host 的 dispatcher，
    # 诊断目标同样编入真实实现（游戏目标由 Runtime.cmake 的 core 列表提供）。
    set(sources
        ../../runtime/src/os.c ../../runtime/src/alt.c ../../runtime/src/direct_host.c ../../graphics/track/track.c
        # 应用池 s2a_app_pool（Switch 2 9 GiB）：plat_android.c 的 layout_android.inc 经 S2A_HEAP_DEFAULT 读它
        ../../runtime/src/layout.c
        runtime/runtime/tracking/platform.c runtime/runtime/tracking/runtime.c
        runtime/runtime/tracking/registry.c
        # #1456 capprobe：诊断单库同样链 bridge.cpp / vk_device.c 引用的探测符号；
        # 探测本体 capprobe.c 只编成独立可执行件（packaged helper），不进单库。
        runtime/capprobe/capprobe_host.c)
    set(${output} "${sources}" PARENT_SCOPE)
endfunction()

function(s2a_android_static_sources output mode)
    # 单库：诊断目标用链接桩顶住尚未在 Android 上运行的共享核心；游戏目标由真实
    # provider 提供同一组符号。只读 guest 复制只在诊断目标需要。
    if(mode STREQUAL "diagnostic")
        # readonly_copy.c 现在也读背板打洞世代号（#1217 §2.6），诊断单库必须带 backing.c。
        set(sources runtime/s2a_native_stub.c runtime/runtime/tracking/readonly_copy.c runtime/runtime/vm/backing.c)
    else()
        set(sources)
    endif()
    set(${output} "${sources}" PARENT_SCOPE)
endfunction()

function(s2a_android_direct_sources output)
    # NVN→Vulkan 直连核心：由 NvnDirect.cmake 的 s2a_android_direct_core() 编进生产目标。
    # 列在这里是为了让 Q19（link_symbols.py）的源码级符号扫描与实际编译源一致，
    # 新增直连导出时只需改这一处，门禁不会漏看。
    set(sources
        runtime/direct/s2a_direct_abi.c runtime/direct/json.c runtime/direct/sha256.c
        runtime/direct/graphics.c runtime/direct/attempt.c runtime/direct/selection.c
        runtime/direct/control.c runtime/direct/vk_device.c runtime/direct/gs_path.c
        runtime/direct/vk_sync.c runtime/direct/vk_track.c
        runtime/direct/vk_membuf.c runtime/direct/vk_resid.c
        runtime/nvn/nvn_vk_poolahb.c runtime/nvn/poolahb_cover.c runtime/nvn/poolahb_policy.c runtime/nvn/poolahb_alias.c
        runtime/nvn/nvn_vk_timeline.c runtime/nvn/nvn_vk_threadbuf.c
        # 逐帧上屏间隔 + 每帧 fence 等待（诊断默认关）：direct/generic 同一份环形缓冲与
        # 转储格式（t-direct-frametimes），generic 经 DllImport 调 s2a_frame_log_present/dump，必须随直连核心编入。
        runtime/nvn/nvn_vk_frame_log.c
        runtime/nvn/nvn_vk_compile_events.c
        runtime/direct/vk_clear.c
        runtime/nvn/nvn_vk_swapchain.c runtime/nvn/nvn_vk_surface.c runtime/nvn/nvn_vk_session.c
        runtime/nvn/nvn_vk_lifecycle.c runtime/nvn/nvn_vk_pipeline.c runtime/nvn/nvn_vk_texcache.c
        runtime/nvn/nvn_vk_bcdec.c
        # NVN ReadTexels：纯几何换算（宿主单测同源）+ guest 内存路径 + GPU 图像路径。
        runtime/nvn/nvn_vk_readback_plan.c runtime/nvn/nvn_vk_readback.c runtime/nvn/nvn_vk_readback_gpu.c
        runtime/nvn/mtl_vk_adapter.c runtime/direct/vk_record.c runtime/direct/t2t_plan.c
        # 批次 1/A：命令流拍平（A2 延迟参数入记录 + A4 记录内引用重定位）；shim 的 clone_append 调用它。
        runtime/direct/record_flat.c
        runtime/nvn/nvn_vk_sampler_cache.c runtime/nvn/nvn_vk_sampler.c runtime/nvn/nvn_vk_format.c
        runtime/nvn/nvn_vk_mrt.c
        runtime/nvn/nvn_vk_program.c runtime/nvn/nvn_vk_draw.c runtime/nvn/nvn_vk_compile_facts.c
        runtime/nvn/nvn_vk_pipe_recipe.c runtime/nvn/nvn_vk_driver_cache.c
        runtime/nvn/nvn_vk_first_draw.c runtime/nvn/nvn_vk_draw_diag.c runtime/nvn/nvn_vk_program_result.c runtime/nvn/nvn_vk_query.c
        runtime/nvn/nvn_vk_compute.c runtime/nvn/nvn_vk_compute_texture.c runtime/nvn/nvn_vk_compute_request.c
        runtime/nvn/nvn_vk_compute_lookup.c runtime/nvn/nvn_vk_compute_bridge.c
        runtime/nvn/nvn_vk_pipe_manifest.c runtime/nvn/nvn_vk_pcprof.c
        runtime/nvn/nvn_vk_exec_owner.c runtime/nvn/nvn_vk_pipe_worker.c
        # 批次 1/D：提交完成事实与批次持有（纯状态机，不碰 Vulkan；批次 2/3 接入消费）。
        runtime/nvn/nvn_vk_completion.c
        runtime/direct/compiler_bind.c runtime/direct/source_store.c runtime/direct/device_caps.c
        runtime/direct/vk_identity.c
        runtime/direct/compile_request.c runtime/direct/diag.c runtime/direct/compile_export.c runtime/direct/compile_export_w2.c runtime/direct/w2_single_query.c runtime/direct/input_identity.c
        runtime/direct/texture_facts.c runtime/direct/compile_worker.c
        runtime/direct/bind_defer.c
        runtime/direct/program_cache.c runtime/direct/offline_library.c
        # Pure texture helpers are needed by the core even without the game frontend.
        ../../graphics/nvn/gfx/nvn/nvn_tex.c ../../graphics/nvn/gfx/tex/nvn_deswizzle.c
        # 纹理缓存（nvn_vk_texcache.c）按页级写跟踪判脏，前端关也引用：nvn_dirty 与它的
        # Android 宿主钩子（dm_* → direct_host）随直连核心编入，不再只挂在前端源列表里。
        ../../graphics/nvn/gfx/nvn/nvn_dirty.c runtime/nvn/nvn_host_hooks.c)
    set(${output} "${sources}" PARENT_SCOPE)
endfunction()

function(s2a_android_link_sources output mode static_services)
    # Full target source set, used by the gate and available to CMake callers that
    # need the same answer as the production target.
    s2a_android_host_sources(host)
    if(mode STREQUAL "game")
        s2a_android_game_sources(mode_sources)
    else()
        s2a_android_diagnostic_sources(mode_sources)
    endif()
    # 直连核心在两种模式都编进生产目标（见 CMakeLists 的 s2a_android_direct_core）。
    s2a_android_direct_sources(direct_sources)
    set(sources ${host} ${mode_sources} ${direct_sources})
    if(static_services STREQUAL "static")
        s2a_android_static_sources(static_sources "${mode}")
        list(APPEND sources ${static_sources})
    endif()
    set(${output} "${sources}" PARENT_SCOPE)
endfunction()
