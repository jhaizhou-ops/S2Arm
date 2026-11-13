// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_IOS_LOCAL_CONTROLLERS_H
#define S2A_IOS_LOCAL_CONTROLLERS_H
#include "s2a_local_input.h"
#include <string.h>
#ifdef __OBJC__
@class UIView;
void s2a_ios_local_attach(UIView *root);
#endif
void s2a_ios_local_set_foreground(int foreground);
void s2a_ios_local_set_split(int split);
int s2a_ios_local_has_controllers(void);

// Public SDL 5403934 MFI -> Ryujinx pre-filter convention, composed once:
// SDL accel=(-GCx,-GCy,-GCz)*g, gyro=(GCrx,GCrz,-GCry).
// NpadController then maps (x,-z,y); MotionInput negates HID accel later.
// https://github.com/libsdl-org/SDL/blob/5403934/src/joystick/apple/SDL_mfijoystick.m#L1196
static inline s2a_local_motion_sample s2a_ios_gc_motion(uint64_t time,
        double ax, double ay, double az, double gx, double gy, double gz) {
    const double deg = 57.29577951308232;
    return (s2a_local_motion_sample){time, (float)-ax, (float)az, (float)-ay,
        (float)(gx * deg), (float)(gy * deg), (float)(gz * deg)};
}
static inline int s2a_ios_motion_fresh(s2a_local_motion_sample sample, uint64_t now) {
    return sample.timestamp_us && now >= sample.timestamp_us && now - sample.timestamp_us <= 250000;
}
// Apply the shared current ABXY choice once after restoring physical coordinates.
static inline s2a_local_input_slot s2a_ios_face_order(s2a_local_input_slot p, const int order[4]) {
    uint32_t face=p.buttons&15u;p.buttons&=~15u;
    for(int i=0;i<4;i++)if(face&(1u<<order[i]))p.buttons|=1u<<i;
    return p;
}
static inline void s2a_ios_merge_virtual(s2a_local_input_slot *p,uint32_t buttons,int32_t axes[4]) {
    if(p->type==8||p->type==16) {
        uint32_t converted=buttons&~(15u|(3u<<6)|(1u<<4));
        const unsigned map[2][4]={{15,12,14,13},{2,0,3,1}};int side=p->type==16;
        for(int i=0;i<4;i++)if(buttons&(1u<<i))converted|=1u<<map[side][i];
        if(buttons&(1u<<6))converted|=1u<<(side?26:24);
        if(buttons&(1u<<7))converted|=1u<<(side?27:25);
        if(buttons&(1u<<4))converted|=1u<<(side?5:4);buttons=converted;
        int32_t x=axes[0],y=axes[1];memset(axes,0,sizeof(int32_t)*4);
        if(side){axes[2]=-y;axes[3]=x;}else{axes[0]=y;axes[1]=-x;}
    }
    p->buttons|=buttons;int32_t *dst=&p->lx;
    for(int i=0;i<4;i++){int64_t sum=(int64_t)dst[i]+axes[i];dst[i]=(int32_t)(sum< -32767?-32767:sum>32767?32767:sum);}
}
#endif
