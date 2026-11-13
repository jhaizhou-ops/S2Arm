// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Generic iOS local controllers. Platform calls stay off the game's HID thread.
// The old phone CoreMotion / phone motor / NS2 BLE path remains the fallback
// when no Joy-Con topology is active.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import "local_controllers.h"
#include "s2a_pad.h"
#include "haptic_retry.h"
#include "pad_liveness.h"
#include "native.h"
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include <time.h>

enum { PAD_PRO = 1, PAD_PAIR = 4, PAD_LEFT = 8, PAD_RIGHT = 16 };
static pthread_mutex_t state_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_local_input_snapshot input_state = {.abi = 2, .size = sizeof input_state};
static s2a_local_feedback_snapshot feedback_state = {.abi = 1, .size = sizeof feedback_state, .slot_count = 8};
typedef struct { s2a_local_vibration pair[2]; uint64_t until_us, sequence; } rumble_mailbox;
static rumble_mailbox rumble[8];
static uint64_t rumble_sequence;
static uint32_t motion_mask;
static _Atomic int has_controllers;
static dispatch_queue_t haptic_queue;
static uint64_t monotonic_us(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000ull + (uint64_t)t.tv_nsec / 1000;
}
static BOOL environment_allows(const char *key) { const char *value=getenv(key); return !value || strcmp(value,"0"); }
// Current game settings remain owned by controller.m; this path does not create preferences.
float s2a_ios_controller_rumble_gain(void);
static float clamp(float v, float lo, float hi) { return isfinite(v) ? fmaxf(lo, fminf(hi, v)) : lo; }
typedef struct {
    s2a_local_vibration pair[2];
    uint64_t session, until_us, sequence;
    uint32_t generation, player;
} haptic_command;
static BOOL feedback_valid(haptic_command command) {
    pthread_mutex_lock(&state_mu);
    BOOL ok = command.player < 8 && command.session && command.session == feedback_state.session &&
        command.generation == feedback_state.generation &&
        (feedback_state.flags & S2A_FEEDBACK_FOCUSED) && (feedback_state.flags & S2A_FEEDBACK_RUMBLE_ALLOWED) &&
        rumble[command.player].sequence == command.sequence && rumble[command.player].until_us == command.until_us;
    pthread_mutex_unlock(&state_mu); return ok;
}

@interface S2ALocalHaptic : NSObject
@property(nonatomic,strong) CHHapticEngine *engine;
@property(nonatomic,strong) id<CHHapticPatternPlayer> player;
@property(nonatomic) BOOL plainOnly;
@property(nonatomic) s2a_hp_state retry;
@property(nonatomic) uint64_t startedUs;
- (void)stop;
@end
@implementation S2ALocalHaptic
- (void)stop { if (_player) [_player stopAtTime:CHHapticTimeImmediate error:nil]; _startedUs = 0; }
@end

@interface S2ALocalDevice : NSObject
@property(nonatomic,strong) GCController *controller;
@property(nonatomic,copy) NSString *key;
@property(nonatomic) unsigned kind;
@property(nonatomic) BOOL osPair;
@property(atomic) BOOL sensorsOn;
@property(atomic) BOOL live;
@property(atomic) uint64_t hapticToken;
@property(atomic) uint64_t motionEpoch;
@property(nonatomic) uint64_t unavailableSinceUs;
@property(nonatomic) s2a_local_motion_sample motionSample;
@property(nonatomic,copy) GCMotionValueChangedHandler motionHandler;
// These objects are touched only on haptic_queue.
@property(nonatomic,strong) NSMutableDictionary<NSString *,S2ALocalHaptic *> *channels;
// Main-thread desired state, including lease deadlines, coalesces updates.
@property(nonatomic,strong) NSDictionary<NSString *,NSData *> *lastDesired;
@end
@implementation S2ALocalDevice
@end

@interface S2ALocalBinding : NSObject
@property(nonatomic,strong) S2ALocalDevice *first, *second;
@property(nonatomic,copy) NSString *key;
@property(nonatomic) unsigned kind;
@end
@implementation S2ALocalBinding
@end

static void fail_haptic(S2ALocalHaptic *channel, NSError *error) {
    s2a_hp_state retry = channel.retry;
    s2a_hp_on_fail(&retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
    if (!retry.reported) { retry.reported = YES; LOG("系统手柄振动不可用：%s（最多重试三次）", error.localizedDescription.UTF8String ?: "no engine"); }
    channel.retry = retry; [channel stop];
}
static void apply_haptic(S2ALocalDevice *device, NSString *locality, haptic_command c, uint64_t token) {
    if (!device.live || device.hapticToken != token || !feedback_valid(c) || monotonic_us() >= c.until_us) return;
    float amplitude = 0, weighted = 0, weights = 0;
    for (int side = 0; side < 2; side++) {
        float lo = clamp(c.pair[side].low_amp, 0, 1), hi = clamp(c.pair[side].high_amp, 0, 1);
        amplitude = fmaxf(amplitude, fmaxf(lo, hi));
        weighted += lo * clamp(c.pair[side].low_hz, 0, 1250) + hi * clamp(c.pair[side].high_hz, 0, 1250); weights += lo + hi;
    }
    S2ALocalHaptic *channel = device.channels[locality];
    if (!channel) { channel = [S2ALocalHaptic new]; device.channels[locality] = channel; }
    if (amplitude <= .001f) { [channel stop]; return; }
    s2a_hp_state retry = channel.retry;
    if (s2a_hp_should_try(&retry, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) == S2A_HP_SKIP) return;
    NSError *error = nil;
    if (!channel.engine) {
        channel.engine = [device.controller.haptics createEngineWithLocality:locality];
        if (!channel.engine) { fail_haptic(channel, nil); return; }
        channel.engine.playsHapticsOnly = YES;
        __weak S2ALocalHaptic *weak = channel;
        void (^reset)(void) = ^{ dispatch_async(haptic_queue, ^{ S2ALocalHaptic *strong = weak; if (strong) { strong.player = nil; strong.startedUs = 0; } }); };
        channel.engine.resetHandler = reset;
        channel.engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { (void)reason; reset(); };
    }
    if (!channel.player) {
        if (![channel.engine startAndReturnError:&error]) { fail_haptic(channel, error); return; }
        // Never an infinite hardware loop: even a stalled process cannot extend
        // a pulse beyond this one-second event without a fresh valid lease.
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:.5]] relativeTime:0 duration:1];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (pattern && !channel.plainOnly) {
            id<CHHapticAdvancedPatternPlayer> advanced=[channel.engine createAdvancedPlayerWithPattern:pattern error:&error];
            if (advanced) channel.player=advanced;
            else {
                // Match the current system-controller fallback: a failed advanced
                // player can invalidate its engine, so retry ordinary playback fresh.
                channel.plainOnly=YES;[channel.engine stopWithCompletionHandler:nil];channel.engine=nil;
                apply_haptic(device,locality,c,token);return;
            }
        } else if (pattern) channel.player=[channel.engine createPlayerWithPattern:pattern error:&error];
        if (!channel.player) { fail_haptic(channel, error); return; }
    }
    // Engine creation may have waited for AVAudioSession. Recheck after IO.
    if (!device.live || device.hapticToken != token || !feedback_valid(c) || monotonic_us() >= c.until_us) { [channel stop]; return; }
    uint64_t now = monotonic_us();
    if (!channel.startedUs || now - channel.startedUs >= 500000) {
        [channel stop];
        if (![channel.player startAtTime:CHHapticTimeImmediate error:&error]) { fail_haptic(channel, error); return; }
        channel.startedUs = now;
    }
    amplitude=clamp(s2a_hp_feel(amplitude)*s2a_ios_controller_rumble_gain(),0,1);
    float hz = weights > 0 ? weighted / weights : 160;
    float sharpness = clamp((hz - 160) / 320 + .3f, 0, 1);
    if (![channel.player sendParameters:@[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:amplitude relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:sharpness-.5f relativeTime:0]] atTime:CHHapticTimeImmediate error:&error]) { fail_haptic(channel, error); return; }
    retry = channel.retry; s2a_hp_on_ok(&retry); channel.retry = retry;
}
static void desired_haptics(S2ALocalDevice *device, NSDictionary<NSString *,NSData *> *desired) {
    if ([device.lastDesired isEqualToDictionary:desired]) return;
    device.lastDesired = [desired copy]; uint64_t token = device.hapticToken + 1; device.hapticToken = token;
    dispatch_async(haptic_queue, ^{
        if (device.hapticToken != token) return;
        for (NSString *key in device.channels.allKeys) if (!desired[key]) [device.channels[key] stop];
        for (NSString *key in desired) {
            haptic_command command; [desired[key] getBytes:&command length:sizeof command];
            apply_haptic(device, key, command, token);
        }
    });
}

static unsigned controller_kind(GCController *controller, BOOL *osPair) {
    NSString *category = controller.productCategory ?: @"";
    *osPair = [category isEqualToString:@"Nintendo Switch Joy-Con (L/R)"];
    if ([category isEqualToString:@"Nintendo Switch Joy-Con (L)"]) return PAD_LEFT;
    if ([category isEqualToString:@"Nintendo Switch Joy-Con (R)"]) return PAD_RIGHT;
    return PAD_PRO;
}
static s2a_local_input_slot sample_full(S2ALocalDevice *device) {
    GCExtendedGamepad *p = device.controller.extendedGamepad;
    GCControllerButtonInput *face[4] = {p.buttonA, p.buttonB, p.buttonX, p.buttonY};
    int order[4]; s2a_pad_abxy_order(s2a_pad_kind(device.controller.productCategory.UTF8String, [p isKindOfClass:GCXboxGamepad.class],
        [p isKindOfClass:GCDualShockGamepad.class] || [p isKindOfClass:GCDualSenseGamepad.class]), s2a_pad_layout(), order);
    GCControllerButtonInput *buttons[16] = {face[order[0]], face[order[1]], face[order[2]], face[order[3]],
        p.leftThumbstickButton,p.rightThumbstickButton,p.leftShoulder,p.rightShoulder,p.leftTrigger,p.rightTrigger,
        p.buttonMenu,p.buttonOptions,p.dpad.left,p.dpad.up,p.dpad.right,p.dpad.down};
    s2a_local_input_slot out = {.type = PAD_PRO};
    for (int i=0;i<16;i++) if (buttons[i].isPressed) out.buttons |= 1u<<i;
    s2a_pad_stick(p.leftThumbstick.xAxis.value,p.leftThumbstick.yAxis.value,&out.lx);
    s2a_pad_stick(p.rightThumbstick.xAxis.value,p.rightThumbstick.yAxis.value,&out.rx);
    return out;
}
static s2a_local_input_slot sample_single(S2ALocalDevice *device) {
    GCExtendedGamepad *p = device.controller.extendedGamepad; BOOL right = device.kind == PAD_RIGHT;
    s2a_local_input_slot out = {.type = device.kind};
    // SDL's public MFI mapping treats single Joy-Con buttons A/X/B/Y as
    // horizontal south/east/west/north. Convert once back to physical bits.
    GCControllerButtonInput *faces[4] = {p.buttonA,p.buttonX,p.buttonB,p.buttonY};
    const unsigned bits[2][4] = {{12,15,13,14},{0,2,1,3}};
    for (int i=0;i<4;i++) if (faces[i].isPressed) out.buttons |= 1u<<bits[right][i];
    if (p.buttonMenu.isPressed || p.buttonOptions.isPressed) out.buttons |= 1u<<(right ? 10 : 11);
    if (p.leftThumbstickButton.isPressed || p.rightThumbstickButton.isPressed) out.buttons |= 1u<<(right ? 5 : 4);
    if (p.leftShoulder.isPressed) out.buttons |= 1u<<(right ? 26 : 24);
    if (p.rightShoulder.isPressed) out.buttons |= 1u<<(right ? 27 : 25);
    // SDL MFI's public GCInputXboxPaddle* mapping, then its single-Joy-Con
    // mapping: the original vertical shoulder/trigger are the side paddles.
    NSDictionary<NSString *,GCControllerButtonInput *> *buttons=device.controller.physicalInputProfile.buttons;
    if (buttons[right?GCInputXboxPaddleOne:GCInputXboxPaddleThree].isPressed) out.buttons |= 1u<<(right?7:6);
    if (buttons[right?GCInputXboxPaddleTwo:GCInputXboxPaddleFour].isPressed) out.buttons |= 1u<<(right?9:8);
    int32_t stick[2]; s2a_pad_stick(p.leftThumbstick.xAxis.value,p.leftThumbstick.yAxis.value,stick);
    if (right) { out.rx = -stick[1]; out.ry = stick[0]; }
    else { out.lx = stick[1]; out.ly = -stick[0]; }
    int order[4];s2a_pad_abxy_order(S2A_PAD_KIND_NINTENDO,s2a_pad_layout(),order);
    return s2a_ios_face_order(out,order);
}
static s2a_local_input_slot sample_binding(S2ALocalBinding *binding) {
    if (binding.first.osPair) { s2a_local_input_slot p=sample_full(binding.first);p.type=PAD_PAIR;return p; }
    if (binding.kind == PAD_PRO) return sample_full(binding.first);
    s2a_local_input_slot a = sample_single(binding.first);
    if (binding.kind != PAD_PAIR) return a;
    s2a_local_input_slot b = sample_single(binding.second);
    return (s2a_local_input_slot){PAD_PAIR,a.buttons|b.buttons,a.lx,a.ly,b.rx,b.ry};
}

@interface S2ALocalHub : NSObject
@property(nonatomic,strong) NSMutableArray<S2ALocalDevice *> *devices;
@property(nonatomic,strong) NSMutableArray *slots;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,weak) UIView *root;
@property(nonatomic) BOOL foreground,split,motionAllowed,rumbleAllowed;
@property(nonatomic) uint32_t generation;
@property(nonatomic) unsigned previousGesture;
@property(nonatomic) uint64_t session;
- (void)poll;
- (void)refreshMenu;
@end
static S2ALocalHub *hub;
@implementation S2ALocalHub
- (instancetype)init {
    if (!(self=[super init])) return nil;
    _devices=[NSMutableArray new];_slots=[NSMutableArray new];
    for (int i=0;i<8;i++) [_slots addObject:NSNull.null];
    _split=YES;_motionAllowed=YES;_rumbleAllowed=YES;_session=1;
    haptic_queue=dispatch_queue_create("s2arm.local-controller.haptics",DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)attachDevice:(S2ALocalDevice *)device {
    __weak S2ALocalDevice *weak=device;
    device.motionHandler=^(GCMotion *motion) {
        S2ALocalDevice *source=weak;if (!source.live || !source.sensorsOn || !motion.hasRotationRate || !motion.hasGravityAndUserAcceleration) return;
        uint64_t epoch=source.motionEpoch;
        GCAcceleration a=motion.acceleration;GCRotationRate r=motion.rotationRate;
        s2a_local_motion_sample sample=s2a_ios_gc_motion(monotonic_us(),a.x,a.y,a.z,r.x,r.y,r.z);
        dispatch_async(dispatch_get_main_queue(), ^{ if (source.live && source.sensorsOn && source.motionEpoch==epoch) source.motionSample=sample; });
    };
    if (device.controller.extendedGamepad.buttonOptions)
        device.controller.extendedGamepad.buttonOptions.preferredSystemGestureState=GCSystemGestureStateDisabled;
}
- (void)changeSession {
    _session++;
    pthread_mutex_lock(&state_mu);motion_mask=0;memset(rumble,0,sizeof rumble);feedback_state.session=0;pthread_mutex_unlock(&state_mu);
    for (S2ALocalDevice *device in _devices) { device.motionEpoch++;device.motionSample=(s2a_local_motion_sample){0};desired_haptics(device,@{}); }
}
- (void)setSplitMode:(BOOL)split {
    if (_split==split) return;
    _split=split;
    for (int i=0;i<8;i++) _slots[i]=NSNull.null;
    [self changeSession];[self refreshMenu];
}
- (void)refreshMenu {
    __weak S2ALocalHub *weak=self;
    BOOL osCombined=NO,individual=NO;
    for(S2ALocalDevice *device in _devices){osCombined|=device.osPair;individual|=device.kind==PAD_LEFT||device.kind==PAD_RIGHT;}
    BOOL combinedOnly=osCombined&&!individual;
    UIAction *(^mode)(NSString *,BOOL)=^UIAction *(NSString *title,BOOL split) {
        UIAction *action=[UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a){(void)a;[weak setSplitMode:split];}];
        action.state=(combinedOnly?!split:self.split==split)?UIMenuElementStateOn:UIMenuElementStateOff;
        if(combinedOnly&&split)action.attributes=UIMenuElementAttributesDisabled;
        return action;
    };
    UIAction *motion=[UIAction actionWithTitle:@"手柄体感" image:nil identifier:nil handler:^(__kindof UIAction *a){
        (void)a;S2ALocalHub *owner=weak;owner.motionAllowed=!owner.motionAllowed;
        [owner changeSession];[owner refreshMenu];[owner poll];}];
    motion.state=_motionAllowed?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *vibration=[UIAction actionWithTitle:@"游戏振动" image:nil identifier:nil handler:^(__kindof UIAction *a){
        (void)a;S2ALocalHub *owner=weak;owner.rumbleAllowed=!owner.rumbleAllowed;
        [owner changeSession];[owner refreshMenu];[owner poll];}];
    vibration.state=_rumbleAllowed?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *notice=[UIAction actionWithTitle:osCombined?@"系统已合并左右 Joy-Con，游戏内无法拆开；请先在系统中分别连接":@"独立体感需系统分别识别左右手柄" image:nil identifier:nil handler:^(__kindof UIAction *a){(void)a;}];
    notice.attributes=UIMenuElementAttributesDisabled;
    _button.menu=[UIMenu menuWithTitle:@"手柄（本局）" children:@[mode(@"Joy-Con 分体横握",YES),mode(@"Joy-Con 合体",NO),motion,vibration,notice]];
}
- (NSArray<S2ALocalBinding *> *)bindings {
    NSMutableArray *out=[NSMutableArray new],*left=[NSMutableArray new],*right=[NSMutableArray new];
    for (S2ALocalDevice *d in _devices) {
        if (d.kind==PAD_LEFT) {[left addObject:d];continue;}
        if (d.kind==PAD_RIGHT) {[right addObject:d];continue;}
        // A single OS-combined profile is one fused controller. Do not claim
        // two independent players/sensors by partitioning this one profile.
        S2ALocalBinding *b=[S2ALocalBinding new];b.first=d;b.kind=d.osPair?PAD_PAIR:PAD_PRO;
        b.key=[d.key stringByAppendingFormat:@":%u",b.kind];[out addObject:b];
    }
    NSUInteger count=MAX(left.count,right.count);
    for(NSUInteger i=0;i<count;i++) {
        if (!_split) {
            if(i>=left.count||i>=right.count) continue;
            S2ALocalBinding *b=[S2ALocalBinding new];b.first=left[i];b.second=right[i];b.kind=PAD_PAIR;
            b.key=[NSString stringWithFormat:@"%@+%@",b.first.key,b.second.key];[out insertObject:b atIndex:MIN(i,out.count)];
        } else {
            for(int side=0;side<2;side++) {
                NSArray *items=side?right:left;if(i>=items.count)continue;
                S2ALocalBinding *b=[S2ALocalBinding new];b.first=items[i];b.kind=side?PAD_RIGHT:PAD_LEFT;
                b.key=[b.first.key stringByAppendingFormat:@":%u",b.kind];[out insertObject:b atIndex:MIN(i*2+side,out.count)];
            }
        }
    }
    return out;
}
- (void)poll {
    NSAssert(NSThread.isMainThread,@"local controller sampling must be on main");
    NSArray<GCController *> *controllers=GCController.controllers;BOOL changed=NO;
    for(S2ALocalDevice *d in _devices.copy) {
        // GCController.controllers is a delayed snapshot. Preserve an object that
        // still exposes its profile, and use the current bounded disconnect grace.
        if(d.controller.extendedGamepad){d.unavailableSinceUs=0;continue;}
        uint64_t now=monotonic_us();
        if(_foreground&&(!d.unavailableSinceUs||now-d.unavailableSinceUs<S2A_SYSTEM_RECHECK_MS*1000ull)) {
            if(!d.unavailableSinceUs)d.unavailableSinceUs=now;continue;
        }
        d.live=NO;if(d.controller.motion.valueChangedHandler==d.motionHandler)d.controller.motion.valueChangedHandler=nil;
        if(d.controller.motion.sensorsRequireManualActivation)d.controller.motion.sensorsActive=NO;
        desired_haptics(d,@{});[_devices removeObject:d];changed=YES;
    }
    for(GCController *c in controllers) {
        if(!c.extendedGamepad)continue;BOOL found=NO;for(S2ALocalDevice *d in _devices)if(d.controller==c){found=YES;break;}
        if(found||_devices.count>=16)continue;
        S2ALocalDevice *d=[S2ALocalDevice new];d.controller=c;BOOL pair=NO;d.kind=controller_kind(c,&pair);d.osPair=pair;
        d.key=[NSString stringWithFormat:@"%p",c];d.live=YES;d.channels=[NSMutableDictionary new];[_devices addObject:d];[self attachDevice:d];changed=YES;
        LOG("系统多人手柄：%s（体感 %s，振动 %s）",c.productCategory.UTF8String?:"GameController",c.motion.hasRotationRate?"可用":"无",c.haptics?"可用":"无");
    }
    unsigned gesture=0;BOOL leftShoulder=NO,rightShoulder=NO;
    if(_foreground)for(S2ALocalDevice *d in _devices)if(d.kind==PAD_LEFT||d.kind==PAD_RIGHT) {
        s2a_local_input_slot p=sample_single(d);unsigned rails=d.kind==PAD_RIGHT?26:24;
        if((p.buttons&(3u<<rails))==(3u<<rails))gesture|=1;
        if(d.kind==PAD_LEFT&&(p.buttons&(1u<<6)))leftShoulder=YES;
        if(d.kind==PAD_RIGHT&&(p.buttons&(1u<<7)))rightShoulder=YES;
    }
    if(leftShoulder&&rightShoulder)gesture|=2;
    unsigned pressed=gesture&~_previousGesture;_previousGesture=gesture;
    if(pressed&1)[self setSplitMode:YES];else if(pressed&2)[self setSplitMode:NO];
    NSArray<S2ALocalBinding *> *desired=[self bindings];
    for(int i=0;i<8;i++) if(_slots[i]!=NSNull.null) {
        S2ALocalBinding *old=_slots[i];BOOL found=NO;
        for(S2ALocalBinding *b in desired)if([b.key isEqual:old.key]){_slots[i]=b;found=YES;break;}
        if(!found){_slots[i]=NSNull.null;changed=YES;}
    }
    for(S2ALocalBinding *b in desired) {
        BOOL found=NO;for(id old in _slots)if(old!=NSNull.null&&[((S2ALocalBinding *)old).key isEqual:b.key]){found=YES;break;}
        if(found)continue;
        int slot=b.kind==PAD_LEFT?0:b.kind==PAD_RIGHT?1:-1;
        if(slot<0||_slots[slot]!=NSNull.null){slot=-1;for(int i=0;i<8;i++)if(_slots[i]==NSNull.null){slot=i;break;}}
        if(slot>=0){_slots[slot]=b;changed=YES;}
    }
    if(changed){_generation++;[self changeSession];[self refreshMenu];}
    BOOL active=NO;
    for(S2ALocalDevice *d in _devices)if(d.kind==PAD_LEFT||d.kind==PAD_RIGHT||d.osPair){active=YES;break;}
    BOOL motionAllowed=_motionAllowed&&environment_allows("S2A_MOTION");
    BOOL rumbleAllowed=_rumbleAllowed&&environment_allows("S2A_RUMBLE")&&s2a_ios_controller_rumble_gain()>0;
    _button.hidden=!active||!_foreground;
    uint64_t now=monotonic_us();
    s2a_local_input_snapshot input={.abi=2,.size=sizeof input,.generation=_generation,.session=_session,.flags=S2A_LOCAL_PRIMARY_COMPLETE|(_foreground?S2A_LOCAL_FOCUSED:0)};
    s2a_local_feedback_snapshot feedback={.abi=1,.size=sizeof feedback,.generation=_generation,.slot_count=8,.session=active&&_foreground?_session:0,
        .flags=(_foreground?S2A_FEEDBACK_FOCUSED:0)|(motionAllowed?S2A_FEEDBACK_MOTION_ALLOWED:0)|(rumbleAllowed?S2A_FEEDBACK_RUMBLE_ALLOWED:0)};
    rumble_mailbox commands[8];uint32_t requested;
    pthread_mutex_lock(&state_mu);memcpy(commands,rumble,sizeof commands);requested=motion_mask;pthread_mutex_unlock(&state_mu);
    NSMutableDictionary<NSString *,NSNumber *> *wantedSensors=[NSMutableDictionary new];
    NSMutableDictionary<NSString *,NSMutableDictionary<NSString *,NSData *> *> *hapticDesired=[NSMutableDictionary new];
    for(S2ALocalDevice *d in _devices){wantedSensors[d.key]=@NO;hapticDesired[d.key]=[NSMutableDictionary new];}
    for(int slot=0;slot<8;slot++) {
        if(_slots[slot]==NSNull.null)continue;
        S2ALocalBinding *b=_slots[slot];input.connected_mask|=1u<<slot;input.slots[slot]=sample_binding(b);
        s2a_local_feedback_slot *f=&feedback.slots[slot];f->type=b.kind;f->connected=1;
        // Apple's combined pair has one fused IMU. Preserve that current source
        // explicitly; it is not two independent physical left/right sensors.
        if(b.kind==PAD_PAIR&&b.first.osPair)f->reserved|=S2A_LOCAL_MOTION_SINGLE_SOURCE;
        for(int side=0;side<2;side++) {
            if(b.kind==PAD_LEFT&&side!=0)continue;if(b.kind==PAD_RIGHT&&side!=1)continue;
            S2ALocalDevice *d=b.kind==PAD_PAIR&&b.second?(side?b.second:b.first):b.first;
            if(d.controller.haptics)f->reserved|=1u<<(8+side);
        }
        for(int side=0;side<2;side++) {
            S2ALocalDevice *d=nil;
            if(b.kind==PAD_PAIR&&b.second)d=side?b.second:b.first;
            else if(b.kind==PAD_PAIR&&b.first.osPair&&side==1)d=b.first;
            else if(b.kind==PAD_RIGHT&&side==1)d=b.first;
            else if((b.kind==PAD_LEFT||b.kind==PAD_PRO)&&side==0)d=b.first;
            if(!d)continue;
            BOOL cap=d.controller.motion&&d.controller.motion.hasRotationRate&&d.controller.motion.hasGravityAndUserAcceleration;
            if(cap)f->reserved|=1u<<side;
            BOOL want=active&&cap&&_foreground&&motionAllowed&&(requested&(1u<<slot));
            if(want)wantedSensors[d.key]=@YES;
            if(want&&s2a_ios_motion_fresh(d.motionSample,now)){f->motion_mask|=1u<<side;f->motion[side]=d.motionSample;}
        }
        if(!_foreground)memset(&input.slots[slot].buttons,0,sizeof(s2a_local_input_slot)-sizeof(uint32_t));
        if(!active||!_foreground||!rumbleAllowed||commands[slot].until_us<=now)continue;
        haptic_command command={.session=_session,.until_us=commands[slot].until_us,.sequence=commands[slot].sequence,.generation=_generation,.player=slot};
        memcpy(command.pair,commands[slot].pair,sizeof command.pair);
        for(int side=0;side<2;side++) {
            S2ALocalDevice *d=b.kind==PAD_PAIR&&b.second?(side?b.second:b.first):b.first;
            if(!d.controller.haptics)continue;
            if(b.kind==PAD_LEFT&&side!=0)continue;if(b.kind==PAD_RIGHT&&side!=1)continue;
            NSString *locality=GCHapticsLocalityDefault;
            NSSet *supported=d.controller.haptics.supportedLocalities;
            BOOL separate=[supported containsObject:GCHapticsLocalityLeftHandle]&&[supported containsObject:GCHapticsLocalityRightHandle];
            BOOL shared=b.kind==PAD_PRO||b.first.osPair;
            if(shared&&separate)locality=side?GCHapticsLocalityRightHandle:GCHapticsLocalityLeftHandle;
            haptic_command part=command;
            if(!shared||separate){part.pair[1-side]=(s2a_local_vibration){0};}
            hapticDesired[d.key][locality]=[NSData dataWithBytes:&part length:sizeof part];
            if(shared&&!separate)break;
        }
    }
    pthread_mutex_lock(&state_mu);input_state=input;feedback_state=feedback;atomic_store(&has_controllers,active);pthread_mutex_unlock(&state_mu);
    for(S2ALocalDevice *d in _devices) {
        BOOL want=active&&[wantedSensors[d.key] boolValue];
        if(active)d.controller.motion.valueChangedHandler=d.motionHandler;
        else if(d.controller.motion.valueChangedHandler==d.motionHandler)d.controller.motion.valueChangedHandler=nil;
        if(d.sensorsOn!=want){d.motionEpoch++;d.sensorsOn=want;d.motionSample=(s2a_local_motion_sample){0};d.controller.motion.sensorsActive=want;}
        desired_haptics(d,hapticDesired[d.key]);
    }
}
@end

void s2a_ios_local_attach(UIView *root) {
    if(hub)return;hub=[S2ALocalHub new];hub.root=root;
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];hub.button=button;
    button.translatesAutoresizingMaskIntoConstraints=NO;button.showsMenuAsPrimaryAction=YES;button.hidden=YES;
    UIButtonConfiguration *c=UIButtonConfiguration.tintedButtonConfiguration;c.title=@"手柄";c.baseBackgroundColor=[UIColor colorWithWhite:0 alpha:.65];c.baseForegroundColor=UIColor.whiteColor;button.configuration=c;
    button.accessibilityIdentifier=@"s2arm.controllers.menu";button.accessibilityLabel=@"手柄、合体分体和反馈设置";
    [root addSubview:button];[NSLayoutConstraint activateConstraints:@[[button.trailingAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [button.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:48],[button.heightAnchor constraintGreaterThanOrEqualToConstant:44]]];
    [hub refreshMenu];
    hub.timer=[NSTimer timerWithTimeInterval:1.0/120 repeats:YES block:^(NSTimer *timer){(void)timer;[hub poll];}];
    [NSRunLoop.mainRunLoop addTimer:hub.timer forMode:NSRunLoopCommonModes];
}
void s2a_ios_local_set_foreground(int foreground) {
    if(!hub)return;if(hub.foreground!=!!foreground){hub.foreground=!!foreground;[hub changeSession];}[hub poll];
}
void s2a_ios_local_set_split(int split) { if(hub)[hub setSplitMode:!!split]; }
int s2a_ios_local_has_controllers(void) { return atomic_load(&has_controllers); }
#define EXPORT __attribute__((visibility("default"),used))
EXPORT int s2a_local_pads_read_v2(s2a_local_input_snapshot *out) {
    if(!out)return 0;pthread_mutex_lock(&state_mu);*out=input_state;int active=atomic_load(&has_controllers);pthread_mutex_unlock(&state_mu);return active;
}
// Optional service commit hook. Dialog/configuration probes only read the pure
// snapshot above; only an actual HID commit may consume the touch/BLE latch.
EXPORT void s2a_local_merge_virtual(uint64_t session,uint32_t generation,s2a_local_input_slot *player0) {
    if(!player0)return;
    pthread_mutex_lock(&state_mu);
    BOOL valid=atomic_load(&has_controllers)&&session&&session==input_state.session&&generation==input_state.generation&&
        (input_state.flags&S2A_LOCAL_FOCUSED)&&(input_state.connected_mask&1);
    pthread_mutex_unlock(&state_mu);
    if(!valid)return;
    int32_t axes[4];s2a_pad_source source;uint32_t buttons=s2a_pad_read(axes,&source);
    if(source!=S2A_PAD_SYSTEM)s2a_ios_merge_virtual(player0,buttons,axes);
}
EXPORT int s2a_local_feedback_read(s2a_local_feedback_snapshot *out) {
    if(!out)return 0;pthread_mutex_lock(&state_mu);*out=feedback_state;int active=atomic_load(&has_controllers);pthread_mutex_unlock(&state_mu);return active;
}
EXPORT void s2a_local_motion_enable(uint64_t session,uint32_t generation,uint32_t players) {
    pthread_mutex_lock(&state_mu);
    if(session&&session==feedback_state.session&&generation==feedback_state.generation)
        motion_mask=(feedback_state.flags&S2A_FEEDBACK_MOTION_ALLOWED)?players&input_state.connected_mask:0;
    pthread_mutex_unlock(&state_mu);
}
EXPORT void s2a_local_rumble_submit(uint64_t session,uint32_t generation,uint32_t player,const s2a_local_vibration pair[2],uint32_t lease_ms) {
    if(!pair||player>=8)return;pthread_mutex_lock(&state_mu);
    if(session&&session==feedback_state.session&&generation==feedback_state.generation&&
       (feedback_state.flags&S2A_FEEDBACK_FOCUSED)&&(feedback_state.flags&S2A_FEEDBACK_RUMBLE_ALLOWED)&&(input_state.connected_mask&(1u<<player))) {
        memcpy(rumble[player].pair,pair,sizeof rumble[player].pair);rumble[player].until_us=monotonic_us()+(uint64_t)MIN(lease_ms,2000)*1000;rumble[player].sequence=++rumble_sequence;
    }
    pthread_mutex_unlock(&state_mu);
}
EXPORT void s2a_local_feedback_stop(uint64_t session,uint32_t generation,uint32_t players) {
    pthread_mutex_lock(&state_mu);
    if(session&&session==feedback_state.session&&generation==feedback_state.generation)
        for(int i=0;i<8;i++)if(players&(1u<<i)){memset(&rumble[i],0,sizeof rumble[i]);rumble[i].sequence=++rumble_sequence;}
    pthread_mutex_unlock(&state_mu);
}
