// 玩家 1 的六轴来源仲裁：纯函数，宿主（ios/controller.m）每帧调一次。
//   只在「有没有样本」这一层做决定，不碰时间 / 锁 / 设备；换源滞回与丢一帧由宿主负责。
#include "motion_pick.h"

int s2a_motion_pick(int input_source, int ns2_known, int gc_known, int phone_known) {
    int phone = phone_known ? S2A_MOTION_PHONE : S2A_MOTION_NONE;
    int gc = gc_known ? S2A_MOTION_GC : S2A_MOTION_NONE;
    int ns2 = ns2_known ? S2A_MOTION_NS2 : S2A_MOTION_NONE;
    switch (input_source) {
        case 1: return ns2 ? ns2 : gc ? gc : phone;          // NS2 Pro 在驱动输入
        case 2: return gc ? gc : ns2 ? ns2 : phone;          // 系统手柄（GCMotion）在驱动输入
        default: return phone ? phone : gc ? gc : ns2;       // 触屏在驱动输入（含未知值：当触屏处理）
    }
}
