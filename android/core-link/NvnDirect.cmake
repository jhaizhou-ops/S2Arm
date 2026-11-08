# The diagnostic WSI probes and the game frontend use the same Vulkan core.
# Keep its sources, header search paths and per-source options together. Including
# this file only defines the function; apply it after the production target exists.
function(s2a_android_direct_core target)
    # 直连源清单由 LinkSources.cmake 的 s2a_android_direct_sources() 单点维护，
    # 生产构建与 Q19 源码级符号扫描读同一份，避免门禁漏掉新增导出。
    s2a_android_direct_sources(direct_sources)
    target_sources(${target} PRIVATE ${direct_sources})
    set_source_files_properties(
        native/nvn/nvn_vk_swapchain.c native/nvn/nvn_vk_session.c native/nvn/nvn_vk_pipeline.c
        native/nvn/nvn_vk_texcache.c native/nvn/nvn_vk_bcdec.c native/nvn/nvn_vk_sampler_cache.c native/nvn/nvn_vk_sampler.c
        native/nvn/nvn_vk_format.c native/nvn/nvn_vk_mrt.c native/nvn/nvn_vk_program.c native/nvn/nvn_vk_draw.c
        native/nvn/nvn_vk_compile_facts.c native/nvn/nvn_vk_pipe_recipe.c native/nvn/nvn_vk_driver_cache.c
        native/nvn/nvn_vk_pipe_manifest.c
        native/nvn/nvn_vk_first_draw.c native/nvn/nvn_vk_draw_diag.c native/nvn/nvn_vk_pcprof.c native/nvn/nvn_vk_query.c native/direct/vk_clear.c
        PROPERTIES COMPILE_FLAGS "-Wno-missing-field-initializers")
    set_source_files_properties(../graphics/nvn/gfx/nvn/nvn_tex.c ../graphics/nvn/gfx/tex/nvn_deswizzle.c
        ../graphics/nvn/gfx/nvn/nvn_dirty.c PROPERTIES COMPILE_OPTIONS "-Wno-error")
    # Paths are relative to android, as are target_sources above.
    set(includes ../..)
    list(APPEND includes ../graphics/nvn/gfx/nvn ../graphics/nvn/gfx/nvn/include ../graphics/nvn
        ../graphics/nvn/host ../graphics/nvn/gfx/tex native/nvn native/nvn/compat native/direct ../runtime/src)
    target_include_directories(${target} PRIVATE ${includes})
    target_compile_definitions(${target} PRIVATE VK_USE_PLATFORM_ANDROID_KHR)
    target_link_options(${target} PRIVATE -Wl,--wrap=_exit -Wl,--wrap=exit)
endfunction()
