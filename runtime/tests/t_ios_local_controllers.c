// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Public MFI sensor units/axes and independent virtual half-pad boundaries.
// Reference: SDL 5403934 SDL_mfijoystick.m:1196-1210. These expected vectors
// are MotionInput.Update inputs; HID acceleration is negated there once.
#include "../../ios/local_controllers.h"
#include "s2a_pad.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void near(float value,double expected) { assert(fabs(value-expected)<0.0001); }
// Like the existing iOS main-thread/liveness tests, inspect the real platform
// wiring that cannot execute in a macOS command-line process (UIKit required).
static void snapshot_read_is_pure(const char *path) {
    FILE *f=fopen(path,"rb");assert(f);assert(!fseek(f,0,SEEK_END));long size=ftell(f);assert(size>0);rewind(f);
    char *source=malloc((size_t)size+1);assert(source);assert(fread(source,1,(size_t)size,f)==(size_t)size);source[size]=0;fclose(f);
    char *read=strstr(source,"EXPORT int s2a_local_pads_read_v2(");assert(read);
    char *commit=strstr(read,"EXPORT void s2a_local_merge_virtual(");assert(commit);
    char saved=*commit;*commit=0;assert(!strstr(read,"s2a_pad_read("));*commit=saved;
    char *next=strstr(commit,"EXPORT int s2a_local_feedback_read(");assert(next);saved=*next;*next=0;
    char *consume=strstr(commit,"s2a_pad_read(");assert(consume);assert(!strstr(consume+1,"s2a_pad_read("));
    assert(strstr(commit,"session==input_state.session")&&strstr(commit,"generation==input_state.generation"));
    *next=saved;free(source);
}
int main(int argc,char **argv) {
    assert(argc==2);snapshot_read_is_pure(argv[1]);
    s2a_local_motion_sample s=s2a_ios_gc_motion(12345,1,2,3,0.5,-1,2);
    assert(s.timestamp_us==12345);
    near(s.ax,-1);near(s.ay,3);near(s.az,-2);
    near(s.gx,28.6478897565);near(s.gy,-57.2957795131);near(s.gz,114.591559026);
    // GC gravity for a flat controller is (0,-1,0). SDL MFI negates it,
    // NpadController maps (x,-z,y), then MotionInput negates acceleration
    // for HID. Test the boundary all the way to the expected downward 1 g;
    // copying Mush8's final HID vector into this pre-filter ABI fails here.
    s=s2a_ios_gc_motion(12346,0,-1,0,0,0,0);
    near(s.ax,0);near(s.ay,0);near(s.az,1);
    near(-s.ax,0);near(-s.ay,0);near(-s.az,-1);
    // A positive rotation about a single GC gyro axis stays on that axis.
    for(int axis=0;axis<3;axis++) {
        double r[3]={0};r[axis]=1;
        s=s2a_ios_gc_motion(500000,0,0,0,r[0],r[1],r[2]);
        const float result[3]={s.gx,s.gy,s.gz};
        for(int out=0;out<3;out++)near(result[out],out==axis?57.2957795131:0);
    }
    // Freshness is based on the actual event stamp; polling never refreshes it.
    s.timestamp_us=500000;
    assert(s2a_ios_motion_fresh(s,500000));
    assert(s2a_ios_motion_fresh(s,750000));
    assert(!s2a_ios_motion_fresh(s,750001));
    assert(!s2a_ios_motion_fresh(s,499999));
    s.timestamp_us=0;assert(!s2a_ios_motion_fresh(s,100));
    // Shared current auto layout preserves Nintendo A/B/X/Y; explicit Xbox swaps once.
    for(int face=0;face<4;face++) {
        s2a_local_input_slot p={.type=16,.buttons=1u<<face};int order[4];
        s2a_pad_abxy_order(S2A_PAD_KIND_NINTENDO,S2A_PAD_LAYOUT_AUTO,order);
        s2a_local_input_slot a=s2a_ios_face_order(p,order);assert(a.buttons==(1u<<face));
        s2a_pad_abxy_order(S2A_PAD_KIND_NINTENDO,S2A_PAD_LAYOUT_XBOX,order);
        a=s2a_ios_face_order(p,order);assert(a.buttons==(1u<<(face^1)));
    }
    // Virtual horizontal right-stick conversion lands in physical RStick once.
    s2a_local_input_slot right={.type=16};int32_t axes[4]={123,456,0,0};
    s2a_ios_merge_virtual(&right,1u<<0,axes);
    assert(right.lx==0&&right.ly==0&&right.rx==-456&&right.ry==123);
    assert(right.buttons==(1u<<2));
    printf("PASS: iOS MFI pre-filter axes/units, final HID gravity sign, real-event freshness, current ABXY, physical right-stick conversion, and pure snapshot/commit-only virtual latch wiring\n");
    return 0;
}
