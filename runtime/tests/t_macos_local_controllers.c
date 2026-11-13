// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Directly exercise production mapping and sampled/mailbox boundaries. No SDL
// initialization, Bluetooth access, or desktop input is performed by this test.
#ifndef S2A_LOCAL_CONTROLLER_IMPL
#define S2A_LOCAL_CONTROLLER_IMPL "../../macos/joycon_local.c"
#endif
#include S2A_LOCAL_CONTROLLER_IMPL
#include <assert.h>
static unsigned checks;
#define CHECK(x) do { checks++; assert(x); } while (0)
static void near_value(float actual,float expected){CHECK(fabsf(actual-expected)<0.0001f);}
int main(void){
    s2a_pad_layout_set(S2A_PAD_LAYOUT_AUTO);
    mini_pad pads[2]={{.buttons=1u<<SOUTH,.x=123,.y=456,.present=1},
                      {.buttons=1u<<EAST,.x=-789,.y=-321,.present=1}};
    s2a_local_pads_snapshot split=compose(pads,1,1,7);
    CHECK(split.abi==1&&split.generation==7&&split.connected_mask==3);
    CHECK(split.slots[0].type==LEFT&&split.slots[0].buttons==(1u<<12));
    CHECK(split.slots[0].lx==456&&split.slots[0].ly==-123&&!split.slots[0].rx&&!split.slots[0].ry);
    CHECK(split.slots[1].type==RIGHT&&split.slots[1].buttons==(1u<<2));
    CHECK(split.slots[1].rx==321&&split.slots[1].ry==-789&&!split.slots[1].lx&&!split.slots[1].ly);
    s2a_local_pads_snapshot pair=compose(pads,0,1,8);
    CHECK(pair.connected_mask==1&&pair.slots[0].type==PAIR);
    CHECK(pair.slots[0].buttons==((1u<<12)|(1u<<2)));
    CHECK(pair.slots[0].lx==456&&pair.slots[0].ry==-789);
    s2a_local_pads_snapshot neutral=compose(pads,1,0,9);
    CHECK(neutral.connected_mask==3&&!neutral.slots[0].buttons&&!neutral.slots[1].buttons);
    CHECK(!neutral.slots[0].lx&&!neutral.slots[1].rx);
    pads[1].present=0;CHECK(compose(pads,1,1,10).connected_mask==1);CHECK(!compose(pads,0,1,10).connected_mask);
    const unsigned nintendo_face[4]={0,2,1,3},xbox_face[4]={1,3,0,2};
    for(int layout=0;layout<3;layout++){
        s2a_pad_layout_set(layout);
        for(int b=0;b<4;b++){
            s2a_local_pad_slot p=physical((mini_pad){.buttons=1u<<b,.x=100,.y=200},1);
            CHECK(p.buttons==(1u<<(layout==S2A_PAD_LAYOUT_XBOX?xbox_face[b]:nintendo_face[b])));
            CHECK(p.rx==-200&&p.ry==100&&!p.lx&&!p.ly); // Undo SDL single-Joy-Con rotation exactly once.
        }
    }
    s2a_pad_layout_set(S2A_PAD_LAYOUT_AUTO);
    mini_pad gesture[2]={{.present=1,.buttons=(1u<<LEFT_SHOULDER)|(1u<<RIGHT_SHOULDER)},{.present=1}};
    CHECK(gestures(gesture)==1);gesture[0].buttons=1u<<LEFT_PADDLE1;gesture[1].buttons=1u<<RIGHT_PADDLE1;CHECK(gestures(gesture)==2);
    const int kinds[3]={SDL_JOYCON_LEFT,SDL_JOYCON_RIGHT,0};
    for(int k=0;k<3;k++){
        dev[0]=(device_state){.kind=kinds[k],.sensors_on=1,.acc_us=500000,.gyr_us=500000};
        dev[0].accel[1]=9.80665f;s2a_local_motion_sample p=motion_read(0,500000);
        CHECK(p.timestamp_us==500000);near_value(p.ax,0);near_value(p.ay,0);near_value(p.az,1);
        CHECK(motion_read(0,750000).timestamp_us==500000);CHECK(!motion_read(0,750001).timestamp_us);
        dev[0].gyr_us=500001;CHECK(!motion_read(0,500000).timestamp_us);
    }
    dev[0]=(device_state){.id=42,.kind=SDL_JOYCON_LEFT};atomic_store(&sensor_focused,1);atomic_store(&sensor_offset,100);
    sensor_event e={.type=SENSOR_EVENT,.timestamp=200000,.which=42,.sensor=2,.data={1,2,3},.sensor_timestamp=55};
    sensor_filter(NULL,&e);CHECK(dev[0].gyr_us==300);e.timestamp=900000;sensor_filter(NULL,&e);CHECK(dev[0].gyr_us==300);
    e.sensor_timestamp++;sensor_filter(NULL,&e);CHECK(dev[0].gyr_us==1000);
    e.data[0]=NAN;e.sensor_timestamp++;sensor_filter(NULL,&e);CHECK(dev[0].gyr_us==1000);
    atomic_store(&sensor_focused,0);e.data[0]=1;sensor_filter(NULL,&e);CHECK(dev[0].gyr_us==1000);
    dev[0]=(device_state){.pad=(SDL_Gamepad*)1,.kind=SDL_JOYCON_LEFT,.last_slot=-1};
    dev[1]=(device_state){.pad=(SDL_Gamepad*)2,.kind=SDL_JOYCON_RIGHT,.last_slot=-1};
    for(int i=0;i<8;i++)binds[i]=(binding){-1,-1,0};
    mappings(1,1);CHECK(binds[0].type==LEFT&&binds[1].type==RIGHT);
    mappings(0,1);CHECK(binds[0].type==PAIR&&binds[0].a==0&&binds[0].b==1&&binds[1].a<0);
    dev[1].kind=0;CHECK(!binding_matches(binds[0])); // A reused table entry must not inherit an unrelated binding.
    raw_input=(s2a_local_input_snapshot){.abi=2,.size=224,.connected_mask=3,.flags=S2A_LOCAL_FOCUSED};
    raw_input.slots[0].type=LEFT;raw_input.slots[1].type=RIGHT;raw_feedback.flags=7;
    s2a_local_input_snapshot combined=raw_input;combined.connected_mask=7;combined.slots[2].type=PRO;
    s2a_local_feedback_slot fallback={.type=PRO,.connected=1,.reserved=0x101};
    s2a_local_pads_commit(&combined,2,&fallback,1);
    s2a_local_input_snapshot read;CHECK(s2a_local_pads_read_v2(&read)==1&&read.connected_mask==7&&read.slots[2].type==PRO);
    CHECK(!(read.flags&S2A_LOCAL_PRIMARY_COMPLETE)); // The HID reader merges virtual input once.
    CHECK(s2a_local_mouse_player()==2);
    s2a_local_input_slot external={.type=PRO,.buttons=2,.lx=321};
    s2a_local_pads_update_external_input(2,&external);s2a_local_pads_read_v2(&read);
    CHECK(read.slots[2].buttons==2&&read.slots[2].lx==321);
    CHECK(read.slots[0].type==LEFT&&read.slots[1].type==RIGHT);
    s2a_local_pads_update_external_input(0,&external);s2a_local_pads_update_external_input(8,&external);
    s2a_local_pads_read_v2(&read);CHECK(read.slots[0].type==LEFT); // Wrong identity / disconnected index cannot replace a half.
    combined.flags=0;s2a_local_pads_commit(&combined,2,&fallback,1);
    s2a_local_pads_update_external_input(2,&external);s2a_local_pads_read_v2(&read);
    CHECK(!read.slots[2].buttons&&!read.slots[2].lx);
    combined.flags=S2A_LOCAL_FOCUSED;s2a_local_pads_commit(&combined,2,&fallback,1);

    s2a_local_vibration v[2]={{.25f,140,.5f,200},{.1f,140,.2f,200}},out[2];int motion;
    s2a_local_motion_enable(read.session,read.generation,4);s2a_local_rumble_submit(read.session,read.generation,2,v,750);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(motion&&out[0].low_amp==.25f);
    s2a_local_rumble_submit(read.session-1,read.generation,2,(s2a_local_vibration[2]){{0},{0}},750);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(out[0].low_amp==.25f);
    s2a_local_pads_commit(&combined,2,&fallback,2);s2a_local_pads_fallback_request(2,&motion,out);CHECK(!motion&&!out[0].low_amp);
    s2a_local_rumble_submit(read.session,read.generation,2,v,750);s2a_local_pads_fallback_request(2,&motion,out);CHECK(!out[0].low_amp);
    s2a_local_pads_read_v2(&read);
    s2a_local_feedback_stop(read.session,read.generation,4);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(!out[0].low_amp);
    s2a_local_rumble_submit(read.session,read.generation,2,(s2a_local_vibration[2]){{0},{0}},750);
    s2a_local_rumble_submit(read.session,read.generation,2,v,250);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(out[0].low_amp==.25f);
    CHECK(commands[2].expires<=now_us()+250000);
    // Activity-only updates with unchanged slots retain input configuration and
    // all existing feedback requests; a true topology generation still resets above.
    s2a_local_pads_read_v2(&read);uint64_t same_session=read.session;uint32_t same_generation=read.generation;
    s2a_local_motion_enable(same_session,same_generation,4);
    for(int activity=0;activity<4;activity++){
        combined.slots[2].buttons=activity&1?1:2;
        s2a_local_pads_commit(&combined,2,&fallback,2);s2a_local_pads_read_v2(&read);
        CHECK(read.session==same_session&&read.generation==same_generation);
        s2a_local_pads_fallback_request(2,&motion,out);CHECK(motion&&out[0].low_amp==.25f);
    }

    s2a_local_feedback_stop(read.session,read.generation,4);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(!out[0].low_amp);
    s2a_local_rumble_submit(read.session,read.generation,2,v,250);commands[2].expires=now_us()-1;
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(!out[0].low_amp);
    s2a_local_rumble_submit(read.session,read.generation,2,v,250);
    combined.flags=0;s2a_local_pads_commit(&combined,2,&fallback,2);
    s2a_local_pads_fallback_request(2,&motion,out);CHECK(!motion&&!out[0].low_amp);
    s2a_local_feedback_stop(read.session,read.generation,4);
    combined.flags=S2A_LOCAL_FOCUSED;s2a_local_pads_commit(&combined,2,&fallback,2);
    setenv("S2A_MOTION","0",1);s2a_local_pads_set_motion(1);CHECK(!s2a_local_pads_motion_enabled());unsetenv("S2A_MOTION");CHECK(s2a_local_pads_motion_enabled());
    setenv("S2A_RUMBLE","0",1);s2a_local_pads_set_rumble(1);CHECK(!s2a_local_pads_rumble_enabled());
    s2a_local_rumble_submit(read.session,read.generation,2,v,250);s2a_local_pads_fallback_request(2,&motion,out);CHECK(!out[0].low_amp);
    unsetenv("S2A_RUMBLE");CHECK(s2a_local_pads_rumble_enabled());
    uint16_t lows[16]={0},highs[16]={0};setenv("S2A_RUMBLE_SCALE","0.5",1);add_rumble(0,&v[0],lows,highs);CHECK(lows[0]==8192&&highs[0]==16384);
    memset(lows,0,sizeof lows);memset(highs,0,sizeof highs);setenv("S2A_RUMBLE_SCALE","2",1);add_rumble(0,&v[0],lows,highs);CHECK(lows[0]==32768&&highs[0]==65535);unsetenv("S2A_RUMBLE_SCALE");
    // A paired layout loses its right half: no playable binding remains,
    // but SDL must retain ownership so legacy GC/HID never reopens that left half.
    memset(dev,0,sizeof dev);dev[0]=(device_state){.pad=(SDL_Gamepad*)1,.kind=SDL_JOYCON_LEFT,.last_slot=-1};
    mappings(0,1);CHECK(binds[0].a<0);
    raw_input=(s2a_local_input_snapshot){.abi=2,.size=224,.flags=S2A_LOCAL_FOCUSED};
    CHECK(s2a_local_pads_prepare(&read)&&!read.connected_mask);
    s2a_local_pads_commit(&raw_input,-1,NULL,3);
    CHECK(s2a_local_pads_read_v2(&read)&&!read.connected_mask&&s2a_local_pads_available());
    dev[0].pad=NULL;CHECK(!s2a_local_pads_prepare(&read));
    s2a_local_pads_commit(&raw_input,-1,NULL,4);CHECK(!s2a_local_pads_read_v2(&read)&&s2a_local_mouse_player()==-1);
    printf("✓ t_macos_local_controllers: %u Mac production mapping/sensor/mailbox/layout/preference checks (no hardware)\n",checks);
}
