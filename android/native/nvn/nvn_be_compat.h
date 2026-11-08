// main 的后端接口名（nvn_be_*）与本线实现名（mtl_*）的编译期对齐（合流兼容层，不改任何一方的函数体）。
//
// main 把共享前端 hle_nvn.c / nvn_mtl.m 的后端入口统一改名成 nvn_be_*；本线的 Android 后端与内部调用
// （mtl_vk_shim.c / nvn_vk.c / vk_nvn_adapter.c 及 nvn_vk_*.c）仍用 mtl_*。两边是同一批函数、同一套签名，
// 这里用宏把标识符统一成 main 的名字：
//   · 后端定义 mtl_addr(...)  →  编译成 nvn_be_addr(...)，共享前端直接链接；
//   · 本线内部调用 mtl_addr(...) → 同样编译成 nvn_be_addr(...)，不会出现两套符号。
// 用 -include 施加到整个 Android 目标（见 android/CMakeLists.txt 与 tools/direct_c5_nvn_test.sh）。
// 新增后端入口时：main 有 nvn_be_X 就在下面补一行；本线独有的 mtl_* 不要加，保持内部名。
#pragma once

#define mtl_addr nvn_be_addr
#define mtl_alias_drop_pool nvn_be_alias_drop_pool
#define mtl_args_stats nvn_be_args_stats
#define mtl_bw nvn_be_bw
#define mtl_create_ns nvn_be_create_ns
#define mtl_create_stats nvn_be_create_stats
#define mtl_display_hz nvn_be_display_hz
#define mtl_drain nvn_be_drain
#define mtl_drawable_ns_take nvn_be_drawable_ns_take
#define mtl_ds_omit nvn_be_ds_omit
#define mtl_exec nvn_be_exec
#define mtl_exec_rest nvn_be_exec_rest
#define mtl_finish nvn_be_finish
#define mtl_fps_target nvn_be_fps_target
#define mtl_gpu_ms nvn_be_gpu_ms
#define mtl_gpu_span nvn_be_gpu_span
#define mtl_has_window nvn_be_has_window
#define mtl_last_fence nvn_be_last_fence
#define mtl_link_active nvn_be_link_active
#define mtl_link_wait_tick nvn_be_link_wait_tick
#define mtl_pkg_stats nvn_be_pkg_stats
#define mtl_pool_add nvn_be_pool_add
#define mtl_pool_del nvn_be_pool_del
#define mtl_present nvn_be_present
#define mtl_presented_time nvn_be_presented_time
#define mtl_present_wait nvn_be_present_wait
#define mtl_prog_release nvn_be_prog_release
#define mtl_read_texels nvn_be_read_texels
#define mtl_reg_samp nvn_be_reg_samp
#define mtl_reg_tex nvn_be_reg_tex
#define mtl_unreg_tex_range nvn_be_unreg_tex_range
#define mtl_set_depth_zero nvn_be_set_depth_zero
#define mtl_set_frame nvn_be_set_frame
#define mtl_set_origin_lower_left nvn_be_set_origin_lower_left
#define mtl_set_tex_pool_n nvn_be_set_tex_pool_n
#define mtl_stats nvn_be_stats
#define mtl_sub_begin nvn_be_sub_begin
#define mtl_sub_commit nvn_be_sub_commit
#define mtl_sub_index nvn_be_sub_index
#define mtl_tex_cpu_written nvn_be_tex_cpu_written
#define mtl_tex_gpu_owned nvn_be_tex_gpu_owned
#define mtl_tex_init nvn_be_tex_init
#define mtl_tex_release nvn_be_tex_release
#define mtl_ub_present nvn_be_ub_present
#define mtl_udc_saved_bytes nvn_be_udc_saved_bytes
#define mtl_upload_bytes nvn_be_upload_bytes
#define mtl_upload_gpu_ns_take nvn_be_upload_gpu_ns_take
#define mtl_upload_ns_take nvn_be_upload_ns_take
#define mtl_use_stats nvn_be_use_stats
#define mtl_wait nvn_be_wait
#define mtl_xv_window_tex nvn_be_xv_window_tex
