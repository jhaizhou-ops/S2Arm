#ifndef S2A_PHONE_RUMBLE_MAILBOX_H
#define S2A_PHONE_RUMBLE_MAILBOX_H
#include "s2a_pad.h"

// 手机震动的提交信箱：提交侧只写固定快照并 signal，立刻返回。
// 为什么必须分开：游戏线程在 HID 的 _rumbleLock 内同步调 s2a_pad_set_rumble*，
//   compat/.../NpadDevices.cs:49 写明「Output hooks run under this same lock. They must not call back from
//   native code or wait for transport IO.」CoreHaptics 起引擎要抢 AVAudioSession（真机实测首次 2049 ms），
//   放进那条调用栈会把音频 / 渲染一起拖停。apply 一律在 mailbox 自己的线程上执行。
typedef enum {
    S2A_PHONE_RUMBLE_WARM = 1,   // 只建引擎 / 播放器，不播放（预热，把首次冷启动挪到没人在等的时候）
    S2A_PHONE_RUMBLE_PLAY = 2,   // 一次左右合成后的震动提交
    S2A_PHONE_RUMBLE_STOP = 3    // 停止；优先级最高，不会被 PLAY 覆盖（pair 连写不得饿死停止）
} s2a_phone_rumble_kind;

// 返回值：pair 非空，WARM/PLAY 用；STOP 时 pair 内容无意义。
typedef void (*s2a_phone_rumble_apply)(const s2a_pad_vibration pair[2], int kind);

typedef struct {
    uint64_t submits, applies, coalesced;   // coalesced = 被后一次提交合并掉的次数（诊断用，不是丢失）
} s2a_phone_rumble_stats;

int  s2a_phone_rumble_mailbox_start(s2a_phone_rumble_apply apply);   // 幂等；0 = 反馈线程没起来
void s2a_phone_rumble_mailbox_submit(const s2a_pad_vibration pair[2]);   // PLAY
void s2a_phone_rumble_mailbox_submit_stop(void);                          // STOP
void s2a_phone_rumble_mailbox_warm(void);                                 // WARM
void s2a_phone_rumble_mailbox_stats_get(s2a_phone_rumble_stats *out);
void s2a_phone_rumble_mailbox_shutdown(void);   // 单测用；生产中不调（进程退出即回收）
#endif
