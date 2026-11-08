// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Original scalar inputs; real production registry helpers and capture body.
// The runner extracts these verbatim. No full adapter TU or Vulkan/device run.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "nvn/nvn_vk_compile_facts.h"
#include "w2_adapter_capture_bodies.inc"
#undef NDEBUG
#include <assert.h>
int __android_log_print(int p,const char*t,const char*f,...){(void)p;(void)t;(void)f;return 0;}
int main(void) {
    int ids[3]={4,7,-1};
    struct nvk_w2_raw_registration raw[3]; uint64_t epoch;
    assert(s2a_vk_adapter_w2_capture_registered(ids,3,raw,&epoch)==0);
    assert(!g_tex_reg && !g_tex_cap && !raw[0].present && !raw[1].present && !raw[2].present);
    tex_t t={0};t.d.format=0x25;t.d.target=0xA;t.d.depth=3;
    s2a_vk_adapter_reg_tex(4,&t,NULL);
    assert(s2a_vk_adapter_w2_capture_registered(ids,3,raw,&epoch)==0);
    assert(raw[0].present && raw[0].format==0x25 && raw[0].target==0xA && raw[0].layers==3);
    assert(!raw[0].view_present && !raw[1].present && !raw[2].present);
    uint64_t first=epoch;
    view_t v={0};v.set_format=1;v.format=0x1;v.target=0x2;v.nlayers=2;
    s2a_vk_adapter_reg_tex(4,&t,&v);
    assert(s2a_vk_adapter_w2_capture_registered(ids,3,raw,&epoch)==0);
    assert(epoch>first && raw[0].view_present && !raw[0].view_complete);
    assert(raw[0].view_format==1 && raw[0].view_target==2 && raw[0].view_layers==2);
    v.set_target=v.set_layers=1;
    s2a_vk_adapter_reg_tex(4,&t,&v);
    assert(s2a_vk_adapter_w2_capture_registered(ids,3,raw,&epoch)==0);
    assert(raw[0].view_complete && raw[0].view_layers==2);
    t.d.depth=0;s2a_vk_adapter_reg_tex(4,&t,NULL);
    assert(s2a_vk_adapter_w2_capture_registered(ids,3,raw,&epoch)==0 && !raw[0].layers);
    assert(s2a_vk_adapter_w2_capture_registered(ids,65,raw,&epoch)!=0);
    puts("PASS actual adapter empty/registered/partial-view/complete-view/zero-layer/bound contracts");
    free(g_tex_reg);g_tex_reg=NULL;g_tex_cap=0;
    return 0;
}
