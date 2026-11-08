// 通用自动玩家 ↔ 宿主接口（测试出包线维护；实现方见各函数注释）。自动玩家只用这里列的信号，不按游戏分支。
#pragma once
#include <stdint.h>

// 按键位 = Switch HidNpadButton 位序（Ryujinx NpadButton 同序）；摇杆伪键由 HID 侧换成满偏摇杆
enum {
    S2A_AP_A = 1u << 0, S2A_AP_B = 1u << 1, S2A_AP_X = 1u << 2, S2A_AP_Y = 1u << 3, S2A_AP_L = 1u << 6, S2A_AP_R = 1u << 7,
    S2A_AP_ZL = 1u << 8, S2A_AP_ZR = 1u << 9, S2A_AP_PLUS = 1u << 10, S2A_AP_MINUS = 1u << 11,
    S2A_AP_LEFT = 1u << 12, S2A_AP_UP = 1u << 13, S2A_AP_RIGHT = 1u << 14, S2A_AP_DOWN = 1u << 15,
    S2A_AP_LS_LEFT = 1u << 16, S2A_AP_LS_UP = 1u << 17, S2A_AP_LS_RIGHT = 1u << 18, S2A_AP_LS_DOWN = 1u << 19,
    S2A_AP_RS_LEFT = 1u << 20, S2A_AP_RS_UP = 1u << 21, S2A_AP_RS_RIGHT = 1u << 22, S2A_AP_RS_DOWN = 1u << 23,
    // 单只 Joy-Con 的 SL / SR（左只位 24 / 25、右只位 26 / 27 都置：游戏按当前那只读；11-03 归族 E：Super Mario Party 横握要 SL+SR）
    S2A_AP_SL = (1u << 24) | (1u << 26), S2A_AP_SR = (1u << 25) | (1u << 27),
};

// —— 自动玩家导出（宿主调） ——
int s2a_autoplay_on(void);          // 开着返回 1（首次调用时起自动玩家线程）。开不开见 ap_default.h
uint32_t s2a_autoplay_keys(void);   // 服务接入线 HID：每次采样手柄时并进这组键（S2A_AP_* 位）
int s2a_autoplay_touch(int32_t *xy, uint32_t *attr);
uint32_t s2a_autoplay_keys2(void);  // 服务接入线 HID：二号手柄的键（驾驶员答「2:键」；接管后二号不再镜像自动玩家给一号的键，真人输入照旧镜像）
// MARK 后段登记（11-04 普查提前收局）：MARK 后要跑完才能收局的段（逻辑速度 A/B、声音稳态窗口、以后新挂的读数窗口）开段时登记、跑完销号。
//   perturb = 1：这段改了出帧状态（A/B 切 60 帧开 / 关），它结束后照常出帧的秒数才从头算；0 = 只旁观（声音窗口）。返回段号（满了 -1，收局不等它、报红）。
//   S2A_AP_EARLY_S=N 时局内段在「登记的段全部销号、且 max(MARK, 最后一个改出帧状态的段结束) 起照常出帧 ≥ N 秒、出图没停」时提前收局。
//   别的层（C# 声音层）按名字取导出（NativeLibrary.TryGetExport），没有自动玩家的包里取不到就不登记
int s2a_ap_seg_open(const char *name, int perturb);
void s2a_ap_seg_close(int id);
int s2a_autoplay_pads(void);        // 服务接入线 HID：自动玩家要的手柄数 1 / 2（第一次按二号手柄时变 2，只增不减），多于当前就接上第二个手柄   // 服务接入线 HID：驾驶员 TOUCH 键的触点（游戏 1280×720，签名同 iOS s2a_vpad_read_touch），返回 0 / 1 个

// —— 宿主提供（自动玩家调） ——
uint64_t s2a_ap_frames(void);       // 累计上屏帧数（原生层 / 渲染器）
uint32_t s2a_ap_draws(void);        // 最近一帧绘制数（帧率能耗线：渲染器计数）
uint32_t s2a_ap_passes(void);       // 最近一帧渲染遍数（直连层 nvn_be_stats；没有 / 通用模式 = 0）：进局读数的第二信号（弱引用，假宿主可不给）
int32_t nxgal_screenshot(void *out, int32_t cap, int32_t *w, int32_t *h);   // 最近一次出图 BGRA8（graphics/metal/gal_abi.h 已有）
int s2a_ap_nominal_fps(void);      // 标称帧率 30 / 60 = 出图实际跟的节拍（60 帧表开且出图间隔放开 = 60；否则游戏设的交换间隔对应的帧率；运行中切换跟着变），0 = 还没上过屏（按 30）（原生层 ap_host.c，各出图路径报进 s2a_nominal_fps_set）
void s2a_ap_audio_mark(void);       // MARK 时调：声音层从此刻起算 60 秒稳态窗口峰值，打「[声] 稳态窗口：输出峰值 X」（服务接入线）
void s2a_ap_shutdown(const char *why);   // 自动玩家跑完：收局退出（原生层）
void s2a_ap_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));   // 写一行 host.log（原生层）
// 可选（dlsym 取，没有就用自动玩家时钟）：uint64_t s2a_ap_game_ns(void) 当前已出帧的游戏时间、uint64_t s2a_ap_shot_ns(void) 本线程上一次截图那帧的游戏时间（纳秒）。
//   逻辑速度探测按它量位移 ÷ 时间、帧数 ÷ 时间；真宿主不给（游戏按真实时间出帧），单测假宿主 t_autoplay.c 给（按出帧累加帧间隔，负载下不失真）
