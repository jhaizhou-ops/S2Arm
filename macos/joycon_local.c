// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Private SDL3 input, real sensor events, and per-player vibration mailboxes.
#include "joycon_local.h"
#include "../runtime/include/s2a_pad.h"
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>
#include <time.h>

typedef struct SDL_Gamepad SDL_Gamepad;
typedef struct {
    uint32_t type, reserved; uint64_t timestamp; uint32_t which; int32_t sensor;
    float data[3]; uint64_t sensor_timestamp;
} sensor_event;
_Static_assert(sizeof(sensor_event)==48, "SDL3 sensor event ABI");
static struct {
    bool (*SetHintWithPriority)(const char *, const char *, int), (*InitSubSystem)(uint32_t);
    void (*QuitSubSystem)(uint32_t), (*SetGamepadEventsEnabled)(bool), (*SetJoystickEventsEnabled)(bool);
    void (*SetEventEnabled)(uint32_t, bool), (*SetEventFilter)(bool (*)(void *, void *),void *);
    void (*UpdateGamepads)(void); uint64_t (*GetTicksNS)(void);
    uint32_t *(*GetGamepads)(int *); int (*GetGamepadTypeForID)(uint32_t);
    SDL_Gamepad *(*OpenGamepad)(uint32_t); void (*CloseGamepad)(SDL_Gamepad *);
    bool (*GamepadConnected)(SDL_Gamepad *), (*GetGamepadButton)(SDL_Gamepad *, int);
    int16_t (*GetGamepadAxis)(SDL_Gamepad *, int);
    bool (*GamepadHasSensor)(SDL_Gamepad *,int), (*SetGamepadSensorEnabled)(SDL_Gamepad *,int,bool);
    bool (*RumbleGamepad)(SDL_Gamepad *,uint16_t,uint16_t,uint32_t);
    const char *(*GetError)(void); void (*free)(void *);
} sdl;
enum { SDL_GAMEPAD=0x2000, SDL_JOYCON_LEFT=8, SDL_JOYCON_RIGHT=9, SENSOR_EVENT=0x659 };
enum { SOUTH,EAST,WEST,NORTH,BACK,GUIDE,START,LEFT_STICK,RIGHT_STICK,LEFT_SHOULDER,RIGHT_SHOULDER,
       DPAD_UP,DPAD_DOWN,DPAD_LEFT,DPAD_RIGHT,MISC1,RIGHT_PADDLE1,LEFT_PADDLE1,RIGHT_PADDLE2,LEFT_PADDLE2 };
enum { PRO=1, PAIR=4, LEFT=8, RIGHT=16, MAX_DEVICES=16 };
typedef struct { uint32_t buttons; int32_t x,y; int present; } mini_pad;
// Undo SDL's mini-gamepad rotation exactly once. The right Joy-Con's stick
// belongs in RStick; using LStick for both halves loses right-only movement.
static s2a_local_pad_slot physical(mini_pad p, int side) {
    s2a_local_pad_slot out = {.type = side ? RIGHT : LEFT};
    const unsigned face[2][4] = {{12, 15, 13, 14}, {0, 2, 1, 3}};
    for (unsigned i = 0; i < 4; i++)
        if (p.buttons & (1u << i)) out.buttons |= 1u << face[side][i];
    if (p.buttons & (1u << START)) out.buttons |= 1u << (side ? 10 : 11);
    if (p.buttons & (1u << LEFT_STICK)) out.buttons |= 1u << (side ? 5 : 4);
    if (p.buttons & (1u << LEFT_SHOULDER)) out.buttons |= 1u << (side ? 26 : 24);
    if (p.buttons & (1u << RIGHT_SHOULDER)) out.buttons |= 1u << (side ? 27 : 25);
    if (p.buttons & (1u << (side ? RIGHT_PADDLE1 : LEFT_PADDLE1))) out.buttons |= 1u << (side ? 7 : 6);
    if (p.buttons & (1u << (side ? RIGHT_PADDLE2 : LEFT_PADDLE2))) out.buttons |= 1u << (side ? 9 : 8);
    if (side) {
        // SDL single-Joy-Con coordinates were undone above. Apply the current Nintendo
        // face-layout rule once, without rotating the physical Joy-Con again.
        int order[4]; s2a_pad_abxy_order(S2A_PAD_KIND_NINTENDO, s2a_pad_layout(), order);
        uint32_t face_buttons = out.buttons & 15u; out.buttons &= ~15u;
        for (int i = 0; i < 4; i++) if (face_buttons & (1u << order[i])) out.buttons |= 1u << i;
        out.rx = -p.y; out.ry = p.x;
    }
    else { out.lx = p.y; out.ly = -p.x; }
    return out;
}
static __attribute__((unused)) s2a_local_pads_snapshot compose(const mini_pad pads[2], int split, int focused, uint32_t gen) {
    s2a_local_pads_snapshot out = {.abi = 1, .generation = gen};
    if (split) {
        for (int side = 0; side < 2; side++) {
            out.slots[side].type = side ? RIGHT : LEFT;
            if (!pads[side].present) continue;
            out.connected_mask |= 1u << side;
            if (focused) out.slots[side] = physical(pads[side], side);
        }
    } else {
        out.slots[0].type = PAIR;
        if (pads[0].present && pads[1].present) {
            out.connected_mask = 1;
            if (focused) {
                s2a_local_pad_slot l = physical(pads[0], 0), r = physical(pads[1], 1);
                out.slots[0] = (s2a_local_pad_slot){PAIR, l.buttons | r.buttons, l.lx, l.ly, r.rx, r.ry};
            }
        }
    }
    return out;
}
static unsigned gestures(const mini_pad p[2]) {
    const uint32_t rails = (1u << LEFT_SHOULDER) | (1u << RIGHT_SHOULDER);
    int split = (p[0].present && (p[0].buttons & rails) == rails) ||
                (p[1].present && (p[1].buttons & rails) == rails);
    int pair = p[0].present && p[1].present &&
               (p[0].buttons & (1u << LEFT_PADDLE1)) && (p[1].buttons & (1u << RIGHT_PADDLE1));
    return (split ? 1u : 0u) | (pair ? 2u : 0u);
}

typedef struct {
    SDL_Gamepad *pad; uint32_t id; int kind, last_slot, sensors_on, sensor_cap, rumble_failed;
    float accel[3], gyro[3]; uint64_t acc_us,gyr_us,hw_acc,hw_gyr;
    uint16_t low,high; uint64_t until_us, renewed_us;
} device_state;
typedef struct { int a,b; uint32_t type; } binding;
typedef struct { s2a_local_vibration values[2]; uint64_t expires; uint64_t session; uint32_t generation; } rumble_command;
static device_state dev[MAX_DEVICES];
static binding binds[8];
static rumble_command commands[8];
static pthread_mutex_t mu=PTHREAD_MUTEX_INITIALIZER;
static s2a_local_input_snapshot input={.abi=2,.size=224};
static s2a_local_feedback_snapshot feedback={.abi=1,.size=672,.slot_count=8};
static s2a_local_input_snapshot raw_input={.abi=2,.size=224};
static s2a_local_feedback_snapshot raw_feedback={.abi=1,.size=672,.slot_count=8};
static uint32_t last_external_generation;
static int last_fallback_slot=-2;
static _Atomic int mouse_player=-1;
static _Atomic uint32_t system_buttons;
static _Atomic int split_mode=1, motion_allowed=1, rumble_allowed=1;
static _Atomic uint32_t recenter;
static _Atomic uint64_t sensor_offset;
static _Atomic int sensor_focused;
static _Atomic uint32_t generation=1;
static uint32_t requested_motion, last_recenter;
static _Atomic uint64_t session=1;
static int attempted,initialized,stopped,owned,last_mode=-1,last_focus=-1,last_motion=-1,last_rumble=-1;
static void *library;
static uint64_t now_us(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000+t.tv_nsec/1000; }
static int32_t axis(int16_t v) { if(v>-4915 && v<4915)return 0; return v < -32767 ? -32767:v; }
static bool sensor_filter(void *unused, void *event) {
    (void)unused; sensor_event *e=event;
    if(e->type!=SENSOR_EVENT || !atomic_load(&sensor_focused) || (e->sensor!=1 && e->sensor!=2))return false;
    if(!isfinite(e->data[0])||!isfinite(e->data[1])||!isfinite(e->data[2]))return false;
    pthread_mutex_lock(&mu);
    for(int i=0;i<MAX_DEVICES;i++)if(dev[i].id==e->which) {
        uint64_t *hw=e->sensor==1?&dev[i].hw_acc:&dev[i].hw_gyr;
        if(e->sensor_timestamp && *hw==e->sensor_timestamp)break;
        *hw=e->sensor_timestamp;
        memcpy(e->sensor==1?dev[i].accel:dev[i].gyro,e->data,sizeof e->data);
        uint64_t stamp=atomic_load(&sensor_offset)+e->timestamp/1000;
        if(e->sensor==1)dev[i].acc_us=stamp;else dev[i].gyr_us=stamp;
        break;
    }
    pthread_mutex_unlock(&mu);
    return false; // SDL private queue is unused; internal gamepad state is still updated.
}
static int initialize(void) {
    if(attempted||stopped)return initialized;
    attempted=1;
    for(int i=0;i<MAX_DEVICES;i++)dev[i].last_slot=-1;
    for(int i=0;i<8;i++)binds[i]=(binding){-1,-1,0};
    char exe[PATH_MAX],path[PATH_MAX];uint32_t n=sizeof exe;
    if(_NSGetExecutablePath(exe,&n)||!realpath(exe,path))return 0;
    char *end=strrchr(path,'/');if(!end)return 0;*end=0;
    if(strlen(path)+sizeof "/libSDL3.dylib">sizeof path)return 0;
    strcat(path,"/libSDL3.dylib");library=dlopen(path,RTLD_NOW|RTLD_LOCAL);
    if(!library){fprintf(stderr,"[s2a] 本地手柄组件未加载：%s\n",dlerror());return 0;}
#define LOAD(name) do { *(void **)(&sdl.name)=dlsym(library,"SDL_" #name);if(!sdl.name)goto fail; }while(0)
    LOAD(SetHintWithPriority);LOAD(InitSubSystem);LOAD(QuitSubSystem);LOAD(SetGamepadEventsEnabled);
    LOAD(SetJoystickEventsEnabled);LOAD(SetEventEnabled);LOAD(SetEventFilter);LOAD(UpdateGamepads);
    LOAD(GetTicksNS);LOAD(GetGamepads);LOAD(GetGamepadTypeForID);LOAD(OpenGamepad);LOAD(CloseGamepad);
    LOAD(GamepadConnected);LOAD(GetGamepadButton);LOAD(GetGamepadAxis);LOAD(GamepadHasSensor);
    LOAD(SetGamepadSensorEnabled);LOAD(RumbleGamepad);LOAD(GetError);LOAD(free);
#undef LOAD
    const char *hints[]={"SDL_JOYSTICK_MFI","SDL_JOYSTICK_HIDAPI","SDL_JOYSTICK_HIDAPI_JOY_CONS",
        "SDL_JOYSTICK_HIDAPI_COMBINE_JOY_CONS","SDL_JOYSTICK_HIDAPI_VERTICAL_JOY_CONS",
        "SDL_GAMECONTROLLER_USE_BUTTON_LABELS","SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"};
    const char *values[]={"0","1","1","0","0","0","1"};
    for(int i=0;i<7;i++)sdl.SetHintWithPriority(hints[i],values[i],2);
    if(!sdl.InitSubSystem(SDL_GAMEPAD))goto fail;
    atomic_store(&sensor_offset,now_us()-sdl.GetTicksNS()/1000);
    sdl.SetGamepadEventsEnabled(false);sdl.SetJoystickEventsEnabled(false);
    sdl.SetEventEnabled(SENSOR_EVENT,true);sdl.SetEventFilter(sensor_filter,NULL);
    initialized=1;return 1;
fail:
    fprintf(stderr,"[s2a] 本地手柄组件启动失败，保留旧输入路径\n");
    dlclose(library);library=NULL;return 0;
}
void s2a_local_pads_set_mode(int split){atomic_store(&split_mode,!!split);}
int s2a_local_pads_mode(void){return atomic_load(&split_mode);}
uint32_t s2a_local_pads_system_buttons(void){return atomic_load(&system_buttons);}
static int preference_allows(const char *name){const char *v=getenv(name);return !v||strcmp(v,"0");}
void s2a_local_pads_set_motion(int on){atomic_store(&motion_allowed,!!on);}
int s2a_local_pads_motion_enabled(void){return atomic_load(&motion_allowed)&&preference_allows("S2A_MOTION");}
void s2a_local_pads_set_rumble(int on){atomic_store(&rumble_allowed,!!on);}
int s2a_local_pads_rumble_enabled(void){return atomic_load(&rumble_allowed)&&preference_allows("S2A_RUMBLE");}
void s2a_local_pads_recenter(void){atomic_fetch_add(&recenter,1);}
int s2a_local_pads_available(void){pthread_mutex_lock(&mu);int r=owned;pthread_mutex_unlock(&mu);return r;}
#define EXPORT __attribute__((visibility("default"),used))
EXPORT int s2a_local_mouse_player(void){return atomic_load(&mouse_player);}
EXPORT int s2a_local_pads_read_v2(s2a_local_input_snapshot *out){
    if(!out)return 0;pthread_mutex_lock(&mu);*out=input;int r=owned;pthread_mutex_unlock(&mu);return r;
}
EXPORT int s2a_local_pads_read(s2a_local_pads_snapshot *out){
    if(!out)return 0;pthread_mutex_lock(&mu);
    *out=(s2a_local_pads_snapshot){.abi=1,.connected_mask=input.connected_mask&3,.generation=input.generation};
    memcpy(out->slots,input.slots,sizeof out->slots);int r=owned;pthread_mutex_unlock(&mu);return r;
}
EXPORT int s2a_local_feedback_read(s2a_local_feedback_snapshot *out){
    if(!out)return 0;pthread_mutex_lock(&mu);*out=feedback;int r=owned;pthread_mutex_unlock(&mu);return r;
}
static int valid_session(uint64_t s,uint32_t g){return s&&s==session&&g==generation&&s==input.session&&g==input.generation&&(input.flags&S2A_LOCAL_FOCUSED);}
EXPORT void s2a_local_motion_enable(uint64_t s,uint32_t g,uint32_t mask){
    pthread_mutex_lock(&mu);if(valid_session(s,g))requested_motion=mask&255;pthread_mutex_unlock(&mu);
}
EXPORT void s2a_local_rumble_submit(uint64_t s,uint32_t g,uint32_t player,const s2a_local_vibration pair[2],uint32_t lease){
    if(player>=8||!pair)return;pthread_mutex_lock(&mu);
    if(valid_session(s,g)&&(input.connected_mask&(1u<<player))&&s2a_local_pads_rumble_enabled()) {
        memcpy(commands[player].values,pair,sizeof commands[player].values);
        commands[player].session=s;commands[player].generation=g;
        commands[player].expires=now_us()+(lease>2000?2000:lease)*1000ull;
    }
    pthread_mutex_unlock(&mu);
}
EXPORT void s2a_local_feedback_stop(uint64_t s,uint32_t g,uint32_t mask){
    pthread_mutex_lock(&mu);if(s==input.session&&g==input.generation)for(int i=0;i<8;i++)if(mask&(1u<<i))commands[i]=(rumble_command){0};pthread_mutex_unlock(&mu);
}
static int free_slot(void){for(int i=0;i<8;i++)if(binds[i].a<0)return i;return -1;}
// A disconnect and a new connection can reuse a device-table entry in one poll.
// Keep its player slot only if the current physical kind still matches the binding.
static int binding_matches(binding b){
    if(b.a<0||b.a>=MAX_DEVICES||!dev[b.a].pad)return 0;
    if(b.b>=0)return b.type==PAIR&&b.b<MAX_DEVICES&&dev[b.b].pad&&
        dev[b.a].kind==SDL_JOYCON_LEFT&&dev[b.b].kind==SDL_JOYCON_RIGHT;
    uint32_t type=dev[b.a].kind==SDL_JOYCON_LEFT?LEFT:dev[b.a].kind==SDL_JOYCON_RIGHT?RIGHT:PRO;
    return b.type==type;
}
static void mappings(int split,int reset){
    int used[MAX_DEVICES]={0};
    for(int i=0;i<8;i++) {
        binding b=binds[i];
        if(reset||!binding_matches(b))binds[i]=(binding){-1,-1,0};
        else {used[b.a]=1;if(b.b>=0)used[b.b]=1;}
    }
    if(!split)for(int l=0;l<MAX_DEVICES;l++)if(dev[l].pad&&!used[l]&&dev[l].kind==SDL_JOYCON_LEFT) {
        for(int r=0;r<MAX_DEVICES;r++)if(dev[r].pad&&!used[r]&&dev[r].kind==SDL_JOYCON_RIGHT) {
            int slot=free_slot();if(slot<0)break;
            binds[slot]=(binding){l,r,PAIR};used[l]=used[r]=1;break;
        }
    }
    // Prefer the first L/R as P1/P2, then retain every active assignment across hotplug.
    for(int pass=0;pass<2;pass++)for(int d=0;d<MAX_DEVICES;d++)if(dev[d].pad&&!used[d]) {
        int side=dev[d].kind==SDL_JOYCON_LEFT?0:dev[d].kind==SDL_JOYCON_RIGHT?1:-1;
        if((side>=0)!=(!pass)||(!split&&side>=0))continue;
        int slot=dev[d].last_slot;
        if(slot<0||slot>=8||binds[slot].a>=0)slot=(side>=0&&binds[side].a<0)?side:free_slot();
        if(slot<0)continue;
        binds[slot]=(binding){d,-1,side==0?LEFT:side==1?RIGHT:PRO};dev[d].last_slot=slot;used[d]=1;
    }
}
static mini_pad mini_read(SDL_Gamepad *p){
    mini_pad m={.present=1};for(int b=0;b<=LEFT_PADDLE2;b++)if(sdl.GetGamepadButton(p,b))m.buttons|=1u<<b;
    m.x=axis(sdl.GetGamepadAxis(p,0));m.y=-axis(sdl.GetGamepadAxis(p,1));return m;
}
static int fresh(uint64_t t,uint64_t now){return t&&now>=t&&now-t<=250000;}
static void set_sensors(device_state *d,int want){
    bool a=sdl.SetGamepadSensorEnabled(d->pad,1,want),g=sdl.SetGamepadSensorEnabled(d->pad,2,want);
    if(want&&(!a||!g)){
        // Roll back a partial enable. A failed rollback stays dirty so an off poll retries it.
        a=sdl.SetGamepadSensorEnabled(d->pad,1,false);g=sdl.SetGamepadSensorEnabled(d->pad,2,false);
        d->sensors_on=a&&g?0:-1;
    }else d->sensors_on=a&&g?want:-1;
}
static s2a_local_motion_sample motion_read(int index,uint64_t now){
    device_state *d=&dev[index];s2a_local_motion_sample s={0};
    if(d->sensors_on!=1||!fresh(d->acc_us,now)||!fresh(d->gyr_us,now))return s;
    const float rad_deg=57.29577951308232f,g=9.80665f;
    float *a=d->accel,*r=d->gyro;s.timestamp_us=d->gyr_us;
    // Undo SDL's single-Joy-Con transform, then use Ryujinx's pre-fusion coordinates.
    // MotionInput negates acceleration for HID after fusion; do not negate it here.
    if(d->kind==SDL_JOYCON_LEFT){s.ax=-a[2]/g;s.ay=-a[0]/g;s.az=a[1]/g;s.gx=-r[2]*rad_deg;s.gy=-r[0]*rad_deg;s.gz=r[1]*rad_deg;}
    else if(d->kind==SDL_JOYCON_RIGHT){s.ax=a[2]/g;s.ay=a[0]/g;s.az=a[1]/g;s.gx=r[2]*rad_deg;s.gy=r[0]*rad_deg;s.gz=r[1]*rad_deg;}
    else{s.ax=a[0]/g;s.ay=-a[2]/g;s.az=a[1]/g;s.gx=r[0]*rad_deg;s.gy=-r[2]*rad_deg;s.gz=r[1]*rad_deg;}
    return s;
}
static float strength(float amp,float hz,float base,float range){
    if(!isfinite(amp)||!isfinite(hz))return 0;return fminf(fmaxf(amp,0),1)*fmaxf(.3f,1-fmaxf(hz-base,0)/range);
}
static void add_rumble(int d,const s2a_local_vibration *v,uint16_t lows[16],uint16_t highs[16]){
    const char *e=getenv("S2A_RUMBLE_SCALE"); float scale=e?strtof(e,NULL):1;
    if(!isfinite(scale)||scale<=0)scale=1;
    uint16_t l=lroundf(65535*fminf(1,scale*strength(v->low_amp,v->low_hz,140,400)));
    uint16_t h=lroundf(65535*fminf(1,scale*strength(v->high_amp,v->high_hz,200,700)));
    if(l>lows[d])lows[d]=l;if(h>highs[d])highs[d]=h;
}
void s2a_local_pads_poll(int focused){
    if(!initialize()||stopped)return;
    int changed=0,newly[16]={0},split=atomic_load(&split_mode);
    atomic_store(&sensor_focused,focused&&s2a_local_pads_motion_enabled());
    sdl.UpdateGamepads();
    for(int d=0;d<16;d++)if(dev[d].pad&&!sdl.GamepadConnected(dev[d].pad)){
        sdl.RumbleGamepad(dev[d].pad,0,0,0);sdl.CloseGamepad(dev[d].pad);
        pthread_mutex_lock(&mu);int last=dev[d].last_slot,kind=dev[d].kind;dev[d]=(device_state){.last_slot=last,.kind=kind};pthread_mutex_unlock(&mu);changed=1;
    }
    int count=0;uint32_t *ids=sdl.GetGamepads(&count);
    for(int i=0;ids&&i<count;i++){
        int exists=0;for(int d=0;d<16;d++)if(dev[d].id==ids[i])exists=1;if(exists)continue;
        int kind=sdl.GetGamepadTypeForID(ids[i]),slot=-1;
        // Keep the current GameController / NS2 backend for every other pad.
        if(kind!=SDL_JOYCON_LEFT&&kind!=SDL_JOYCON_RIGHT)continue;
        for(int d=0;d<16;d++)if(!dev[d].pad&&dev[d].kind==kind){slot=d;break;}
        if(slot<0)for(int d=0;d<16;d++)if(!dev[d].pad){slot=d;break;}
        if(slot<0)break;
        SDL_Gamepad *p=sdl.OpenGamepad(ids[i]);if(!p)continue;
        int cap=sdl.GamepadHasSensor(p,1)&&sdl.GamepadHasSensor(p,2);
        pthread_mutex_lock(&mu);int last=dev[slot].last_slot;
        dev[slot]=(device_state){.pad=p,.id=ids[i],.kind=kind,.last_slot=last,.sensor_cap=cap};pthread_mutex_unlock(&mu);
        newly[slot]=1;changed=1;
    }
    sdl.free(ids);
    mini_pad first[2]={{0}};
    for(int d=0;d<16;d++)if(dev[d].pad){int side=dev[d].kind==SDL_JOYCON_LEFT?0:dev[d].kind==SDL_JOYCON_RIGHT?1:-1;if(side>=0&&!first[side].present)first[side]=mini_read(dev[d].pad);}
    // Home belongs to the existing frontend confirmation UI, never HID stick bits.
    uint32_t system=0;
    for(int side=0;side<2;side++)if(first[side].present){
        if(first[side].buttons&(1u<<GUIDE))system|=1;
        if(side){uint32_t face=physical(first[side],1).buttons;if(face&1)system|=2;if(face&2)system|=4;}
    }
    if(first[0].present&&first[1].present&&(first[0].buttons&(1u<<START))&&(first[1].buttons&(1u<<START)))system|=8;
    atomic_store(&system_buttons,system);
    static unsigned previous_gesture;
    unsigned gesture=focused?gestures(first):0;
    if((gesture&~previous_gesture)&1)s2a_local_pads_set_mode(1);else if((gesture&~previous_gesture)&2)s2a_local_pads_set_mode(0);
    previous_gesture=gesture;split=atomic_load(&split_mode);
    int mode_changed=last_mode!=split;
    if(changed||mode_changed){mappings(split,mode_changed);generation++;}
    int ma=s2a_local_pads_motion_enabled(),ra=s2a_local_pads_rumble_enabled();uint32_t rc=atomic_load(&recenter);
    int reset=changed||mode_changed||last_focus!=focused||last_motion!=ma||last_rumble!=ra||last_recenter!=rc;
    if(reset){
        pthread_mutex_lock(&mu);session++;requested_motion=0;memset(commands,0,sizeof commands);
        for(int d=0;d<16;d++)dev[d].acc_us=dev[d].gyr_us=dev[d].hw_acc=dev[d].hw_gyr=0;
        pthread_mutex_unlock(&mu);
        for(int d=0;d<16;d++)if(dev[d].pad&&!newly[d]){sdl.RumbleGamepad(dev[d].pad,0,0,0);dev[d].low=dev[d].high=0;dev[d].until_us=0;}
    }
    last_mode=split;last_focus=focused;last_motion=ma;last_rumble=ra;last_recenter=rc;
    uint32_t desired;rumble_command cmd[8];pthread_mutex_lock(&mu);desired=requested_motion;memcpy(cmd,commands,sizeof cmd);pthread_mutex_unlock(&mu);
    int sensor_wanted[16]={0};uint16_t lows[16]={0},highs[16]={0};uint64_t now=now_us();
    s2a_local_input_snapshot frame={.abi=2,.size=224,.generation=generation,.session=session,.flags=focused?S2A_LOCAL_FOCUSED:0};
    s2a_local_feedback_snapshot fb={.abi=1,.size=672,.generation=generation,.slot_count=8,.session=session,
        .flags=(focused?S2A_FEEDBACK_FOCUSED:0)|(ma?S2A_FEEDBACK_MOTION_ALLOWED:0)|(ra?S2A_FEEDBACK_RUMBLE_ALLOWED:0)};
    for(int i=0;i<8;i++)if(binds[i].a>=0){
        binding b=binds[i];frame.connected_mask|=1u<<i;frame.slots[i].type=b.type;
        if(focused){
            if(b.type==PAIR){s2a_local_pad_slot l=physical(mini_read(dev[b.a].pad),0),r=physical(mini_read(dev[b.b].pad),1);frame.slots[i]=(s2a_local_input_slot){PAIR,l.buttons|r.buttons,l.lx,l.ly,r.rx,r.ry};}
            else if(b.type==LEFT||b.type==RIGHT){s2a_local_pad_slot s=physical(mini_read(dev[b.a].pad),b.type==RIGHT);memcpy(&frame.slots[i],&s,sizeof s);}

        }
        fb.slots[i].type=b.type;fb.slots[i].connected=1;
        int indices[2]={b.a,b.b};int sides[2]={b.type==RIGHT?1:0,1};
        for(int j=0;j<(b.b>=0?2:1);j++){
            int d=indices[j],side=sides[j];
            if(dev[d].sensor_cap)fb.slots[i].reserved|=1u<<side;
            if(!dev[d].rumble_failed)fb.slots[i].reserved|=1u<<(8+side);
            sensor_wanted[d]=focused&&ma&&(desired&(1u<<i));
            if(focused&&ra&&cmd[i].session==session&&cmd[i].generation==generation&&cmd[i].expires>now){
                if(b.type==PAIR||b.type==LEFT||b.type==RIGHT)add_rumble(d,&cmd[i].values[side],lows,highs);
                else{add_rumble(d,&cmd[i].values[0],lows,highs);add_rumble(d,&cmd[i].values[1],lows,highs);}
            }
        }
    }
    for(int d=0;d<16;d++)if(dev[d].pad){
        int want=sensor_wanted[d]&&dev[d].sensor_cap;
        if(want!=dev[d].sensors_on)set_sensors(&dev[d],want);
        if(lows[d]!=dev[d].low||highs[d]!=dev[d].high||((lows[d]||highs[d])&&now-dev[d].renewed_us>=250000)){
            if(!sdl.RumbleGamepad(dev[d].pad,lows[d],highs[d],(lows[d]||highs[d])?500:0)&&!dev[d].rumble_failed){dev[d].rumble_failed=1;fprintf(stderr,"[s2a] 此手柄未提供可用游戏振动：%s\n",sdl.GetError());}
            dev[d].low=lows[d];dev[d].high=highs[d];dev[d].renewed_us=now;
        }
    }
    pthread_mutex_lock(&mu);
    for(int i=0;i<8;i++)if(binds[i].a>=0&&focused&&ma){binding b=binds[i];int ix[2]={b.a,b.b},side[2]={b.type==RIGHT?1:0,1};for(int j=0;j<(b.b>=0?2:1);j++){s2a_local_motion_sample m=motion_read(ix[j],now);fb.slots[i].motion[side[j]]=m;if(m.timestamp_us)fb.slots[i].motion_mask|=1u<<side[j];}}
    raw_input=frame;raw_feedback=fb;
    if(!focused&&owned){
        input.flags&=~S2A_LOCAL_FOCUSED;input.session=session;input.generation=generation;
        for(int i=0;i<8;i++){input.slots[i].buttons=0;input.slots[i].lx=input.slots[i].ly=input.slots[i].rx=input.slots[i].ry=0;}
        feedback.flags&=~S2A_FEEDBACK_FOCUSED;feedback.session=session;feedback.generation=generation;
        for(int i=0;i<8;i++)feedback.slots[i].motion_mask=0;
    }
    pthread_mutex_unlock(&mu);
    if(changed||mode_changed)fprintf(stderr,"[s2a] 本地手柄：%s，玩家掩码 0x%x\n",split?"分体横握":"合体",frame.connected_mask);
}
// The frontend appends its existing GameController/NS2 slots and commits one
// complete frame. Readers cannot observe the intermediate SDL-only topology.
// A paired binding can be empty while SDL still owns one physical half.
// Keep the neutral local path until every opened SDL device is released.
// Called with mu held, like all access to the published snapshots.
static int owns_devices(void) {
    for (int i=0;i<MAX_DEVICES;i++) if (dev[i].pad) return 1;
    return 0;
}
int s2a_local_pads_prepare(s2a_local_input_snapshot *out){
    pthread_mutex_lock(&mu);*out=raw_input;int yes=owns_devices();pthread_mutex_unlock(&mu);return yes;
}
void s2a_local_pads_commit(const s2a_local_input_snapshot *frame,int fallback_slot,
                           const s2a_local_feedback_slot *fallback,uint32_t external_generation){
    pthread_mutex_lock(&mu);
    int yes=owns_devices();
    if(owned!=yes||last_external_generation!=external_generation||last_fallback_slot!=fallback_slot){
        session++;requested_motion=0;memset(commands,0,sizeof commands);
        if(last_external_generation!=external_generation)generation++;
    }
    last_external_generation=external_generation;last_fallback_slot=fallback_slot;owned=yes;
    input=*frame;input.generation=generation;input.session=session;
    feedback=raw_feedback;feedback.generation=generation;feedback.session=session;
    if(yes&&fallback_slot>=0&&fallback_slot<8&&fallback){feedback.slots[fallback_slot]=*fallback;}
    atomic_store(&mouse_player,yes?fallback_slot:-1);
    pthread_mutex_unlock(&mu);
}
// GC's serial fast callback updates only its already assigned local slot.
// A changed topology is installed by the main-thread commit before callbacks
// can observe the new slot mapping (both paths hold the composition lock).
void s2a_local_pads_update_external_input(int slot, const s2a_local_input_slot *state) {
    if (!state || slot < 0 || slot >= S2A_LOCAL_MAX_PLAYERS) return;
    pthread_mutex_lock(&mu);
    if ((input.connected_mask & (1u << slot)) && input.slots[slot].type == state->type) {
        input.slots[slot] = *state;
        if (!(input.flags & S2A_LOCAL_FOCUSED)) {
            input.slots[slot].buttons = 0;
            input.slots[slot].lx = input.slots[slot].ly = input.slots[slot].rx = input.slots[slot].ry = 0;
        }
    }
    pthread_mutex_unlock(&mu);
}
void s2a_local_pads_feedback_update(int slot,const s2a_local_feedback_slot *value){
    if(slot<0||slot>=8||!value)return;
    pthread_mutex_lock(&mu);if(owned)feedback.slots[slot]=*value;pthread_mutex_unlock(&mu);
}
// Called by the main-thread frontend for the original primary GC/NS2 hardware.
// A stale service submission never reaches that backend after a topology/focus reset.
void s2a_local_pads_fallback_request(int slot,int *motion,s2a_local_vibration pair[2]){
    *motion=0;memset(pair,0,2*sizeof *pair);
    pthread_mutex_lock(&mu);
    if(slot>=0&&slot<8&&valid_session(input.session,input.generation)){
        *motion=s2a_local_pads_motion_enabled()&&((requested_motion>>slot)&1);
        rumble_command c=commands[slot];
        if(s2a_local_pads_rumble_enabled()&&c.session==session&&c.generation==generation&&c.expires>now_us())memcpy(pair,c.values,sizeof c.values);
    }
    pthread_mutex_unlock(&mu);
}
void s2a_local_pads_shutdown(void){
    if(stopped)return;stopped=1;atomic_store(&sensor_focused,0);
    if(initialized){sdl.SetEventFilter(NULL,NULL);for(int d=0;d<16;d++)if(dev[d].pad){sdl.RumbleGamepad(dev[d].pad,0,0,0);sdl.CloseGamepad(dev[d].pad);dev[d].pad=NULL;}sdl.QuitSubSystem(SDL_GAMEPAD);initialized=0;}
    pthread_mutex_lock(&mu);input=(s2a_local_input_snapshot){.abi=2,.size=224,.generation=++generation,.session=++session};feedback=(s2a_local_feedback_snapshot){.abi=1,.size=672,.generation=generation,.slot_count=8};memset(commands,0,sizeof commands);pthread_mutex_unlock(&mu);
}
