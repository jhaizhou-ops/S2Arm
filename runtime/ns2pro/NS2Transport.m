// 原生 Switch 2 Pro BLE：工厂校准输入、顺序命令握手、双侧有界震动 mailbox。
// Native Switch 2 Pro BLE: factory-calibrated input, ordered handshake and a bounded two-side rumble mailbox.
// 协议依据 / Protocol references:
// https://github.com/ndeadly/switch2_controller_research (bluetooth_interface.md, commands.md, hid_reports.md)
// https://github.com/murphyjt/wavebird (BLE / NS2Commands, MIT)
// https://github.com/caqlayan/procon2-mac (BLEController, MIT)
// 仅采用协议布局与校准关系，生命周期和线程模型为本桥独立实现。
// Protocol layouts and calibration relations inform this independently implemented lifecycle and threading model.
/*
MIT License
Copyright (c) 2026 jhaizhou
Copyright (c) 2026 Joshua Murphy
Copyright (c) 2026 Arda Caglayan Ercan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
*/
#import <CoreBluetooth/CoreBluetooth.h>
#include "NS2Transport.h"
#include <math.h>
#include <pthread.h>
#include <errno.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define LOG(...) do { fprintf(stderr, "[NS2Transport] "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
#define NS2Localized(key) NSLocalizedStringFromTable((key), @"Transport", nil)
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static NSString *const serviceUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD0";
static NSString *const inputUUID = @"AB7DE9BE-89FE-49AD-828F-118F09DF7FD2";
static NSString *const powerUUID = @"7492866C-EC3E-4619-8258-32755FFCC0F8";
static NSString *const vibrationUUID = @"CC483F51-9258-427D-A939-630C31F72B05";
static NSString *const commandUUID = @"649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005";
static NSString *const responseUUID = @"C765A961-D9D8-4D36-A20A-5315B111836A";
static NSString *const lastReadyPeripheralKey = @"S2ArmNS2ProLastReadyPeripheralIdentifier";

// 调用线程只更新固定 mailbox；CB 对象始终局限于串行队列，不逐请求创建 block。
// Caller threads only update the fixed mailbox; CB objects stay on one serial queue, without a block per request.
static pthread_mutex_t stateMu = PTHREAD_MUTEX_INITIALIZER;
static ns2_vibration wanted[2], actual[2];
static uint64_t wantedDeadline[2];
static BOOL active, ready, terminal = YES, shutdownSent;
static unsigned wantedMask, submittedMask, stopMask;
static uint64_t rumbleRequests, quantizedSilentRequests;
static dispatch_queue_t bleQueue;
static dispatch_group_t shutdownGroup;
static dispatch_source_t mailboxWake;
static char queueKey;
static float rumbleGain = 2;
static ns2_info deviceInfo;
static ns2_motion latestMotion;
static BOOL motionRequested;
static ns2_state_callback stateCallback;
static ns2_status_callback statusCallback;
static ns2_motion_callback motionCallback;
static void *callbackContext;
static BOOL disposing;
static void emit_state(ns2_state value) { if (stateCallback) stateCallback(&value, callbackContext); }
static void emit_status(ns2_status value, NSString *message) { if (statusCallback) statusCallback(value, message.UTF8String, callbackContext); }
static void on_queue(dispatch_block_t block) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bleQueue = dispatch_queue_create("ns2pro.transport.ble", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(bleQueue, &queueKey, &queueKey, NULL);
    });
    if (dispatch_get_specific(&queueKey)) block(); else dispatch_sync(bleQueue, block);
}

typedef struct { unsigned center[2], above[2], below[2]; } ns2_calibration;
static void unpack12(const uint8_t *p, unsigned out[2]) {
    out[0] = p[0] | (p[1] & 15u) << 8; out[1] = p[1] >> 4 | (unsigned)p[2] << 4;
}
static uint32_t le32(const uint8_t *p) { return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static BOOL uuid_is(CBUUID *uuid, NSString *text) { return [uuid isEqual:[CBUUID UUIDWithString:text]]; }
static BOOL value_effective(ns2_vibration value) {
    ns2_rumble_amplitudes codes = ns2_rumble_amplitude_codes(value, rumbleGain);
    return codes.low || codes.high;
}
static void reset_state(void) {
    pthread_mutex_lock(&stateMu);
    // 断线后立即丢弃旧物理连接的输入和震动数值。
    // Immediately discard old physical input and rumble values after disconnection.
    ready = NO; deviceInfo.ready = 0; wantedMask = submittedMask = stopMask = 0;
    rumbleRequests = quantizedSilentRequests = 0;
    memset(&latestMotion, 0, sizeof latestMotion);
    ns2_decode_report09_accessories(NULL, 0, &deviceInfo);
    memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
    pthread_mutex_unlock(&stateMu);
}
static int32_t calibrated_axis(unsigned raw, ns2_calibration cal, unsigned axis) {
    int delta = (int)raw - (int)cal.center[axis];
    double normalized = (double)delta / (delta >= 0 ? cal.above[axis] : cal.below[axis]);
    // 明示 8% 的宿主死区，工厂中心和正负量程分别缩放；不自动学习玩家当前偏转。
    // Use an explicit 8% host deadzone with factory center and separate extents; never learn a held stick as neutral.
    double magnitude = fmin(1.0, fabs(normalized));
    return magnitude <= .08 ? 0 : (int32_t)(copysign((magnitude - .08) / .92, normalized) * NS2_STICK_MAX);
}

typedef NS_ENUM(unsigned, NS2SoftState) {
    NS2SoftRunning, NS2SoftDraining, NS2SoftUnsubscribingPower, NS2SoftPaused, NS2SoftFreshInput
};
@interface NS2Bridge : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate> {
    CBCentralManager *central;
    CBPeripheral *device;
    CBCharacteristic *input, *power, *vibration, *command, *response;
    NSMutableDictionary<NSUUID *, NSNumber *> *retryAfter;
    dispatch_source_t timer;
    ns2_calibration calibration[2];
    NSUInteger step;
    NSData *pendingCommand;
    BOOL awaitingAck, subscribedResponse, streamReady, sessionFailed, preferReport09, imuEnabled, motionCommand;
    uint64_t deadline, scanDeadline, linkStarted, lastRumble, reports, reports09, rumblePackets, effectivePackets, stopPackets;
    const char *waitingFor;
    BOOL scanRequested, initialConnectionRequested;
    NS2SoftState softState;
    BOOL pauseWanted, pauseStopPending, resumeCounterKnown, powerSubscribePending;
    uint32_t resumeCounter;
    uint64_t pauseStarted, resumeStarted;
    uint8_t sequence;
}
- (NSUInteger)initializationSteps;
- (void)tick;
- (void)processEvents;
- (void)scheduleTimer;
- (void)beginSession;
- (void)scan;
- (void)connectPeripheral:(CBPeripheral *)peripheral name:(NSString *)name RSSI:(NSNumber *)rssi;
- (int)rescan;
- (int)suspend;
- (int)resume;
- (void)advanceSoftState;
- (void)fail:(NSString *)reason;
- (void)stop;
- (void)resetLink;
- (void)dispose;
- (void)telemetryFailed:(NSString *)reason;
- (void)publishInput:(NSData *)data report:(unsigned)reportID;
@end
static NS2Bridge *bridge;

@implementation NS2Bridge
- (instancetype)init {
    if ((self = [super init])) {
        retryAfter = [NSMutableDictionary new];
        initialConnectionRequested = YES;
        central = [[CBCentralManager alloc] initWithDelegate:self queue:bleQueue options:nil];
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, bleQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
        __weak NS2Bridge *weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { [weakSelf tick]; } });
        dispatch_resume(timer);
        // 合并跨线程 mailbox 唤醒，空闲时不产生周期唤醒，也不为每个震动请求分配 block。
        // Coalesce cross-thread mailbox wakes without idle polling or one allocated block per rumble request.
        dispatch_source_t wake = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, bleQueue);
        dispatch_source_set_event_handler(wake, ^{ @autoreleasepool { [weakSelf tick]; } });
        dispatch_resume(wake);
        pthread_mutex_lock(&stateMu); mailboxWake = wake; pthread_mutex_unlock(&stateMu);
    }
    return self;
}
- (void)beginSession {
    if (self != bridge || !initialConnectionRequested || device || central.state != CBManagerStatePoweredOn) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) return;
    initialConnectionRequested = NO;
    // 只复用曾完成握手的真实系统标识；retrieve 不扫描，失效标识或空结果才进入首次扫描。
    // Reuse only a real system identifier that completed initialization; retrieval does not scan, and invalid or absent results start discovery.
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:lastReadyPeripheralKey];
    NSUUID *identifier = saved ? [[NSUUID alloc] initWithUUIDString:saved] : nil;
    // 其他同团队游戏可能刚释放前台；先接管系统仍持有的同一外设，不凭共同服务 UUID 选其他设备。
    // Match the remembered identifier before attaching to a peripheral already connected to the system.
    if (identifier) {
        for (CBPeripheral *candidate in [central retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:serviceUUID]]]) {
            if (![candidate.identifier isEqual:identifier]) continue;
            LOG("NS2 Pro BLE 复用系统已连接的已知外设");
            [self connectPeripheral:candidate name:candidate.name RSSI:nil]; return;
        }
    }
    CBPeripheral *known = identifier ? [central retrievePeripheralsWithIdentifiers:@[identifier]].firstObject : nil;
    if (known) {
        [self connectPeripheral:known name:known.name RSSI:nil];
        return;
    }
    scanRequested = YES;
    [self scan];
}
- (void)scan {
    if (self != bridge) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!stopped && scanRequested && !device && !central.isScanning && central.state == CBManagerStatePoweredOn) {
        // 配对广播不保证包含服务 UUID，因此前台保留无过滤扫描，但禁止重复广播且只扫描十秒。
        // Pairing advertisements may omit service UUIDs; keep an unfiltered foreground scan without duplicates for ten seconds.
        scanDeadline = now_ns() + 10ull * NSEC_PER_SEC;
        [central scanForPeripheralsWithServices:nil options:nil];
        emit_status(NS2_STATUS_SCANNING, NS2Localized(@"Searching for a Switch 2 Pro in pairing mode"));
        [self scheduleTimer];
    }
}
- (int)rescan {
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (self != bridge || stopped || device) return 0;
    if (central.state != CBManagerStatePoweredOn && central.state != CBManagerStateUnknown && central.state != CBManagerStateResetting) {
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:NS2Localized(@"Bluetooth unavailable (state %ld). Check Bluetooth power and permission."), (long)central.state]);
        return 0;
    }
    initialConnectionRequested = NO;
    scanRequested = YES;
    scanDeadline = 0;
    [central stopScan];
    [retryAfter removeAllObjects];
    [self scan];
    return 1;
}
- (void)dispose {
    disposing = YES;
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    pthread_mutex_lock(&stateMu);
    dispatch_source_t wake = mailboxWake; mailboxWake = nil;
    pthread_mutex_unlock(&stateMu);
    if (wake) dispatch_source_cancel(wake);
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
    if (device) { device.delegate = nil; [central cancelPeripheralConnection:device]; }
    central.delegate = nil;
    [self resetLink];
    emit_status(NS2_STATUS_STOPPED, NS2Localized(@"Connection stopped"));
    disposing = NO;
}
- (void)resetLink {
    // 连接级状态必须整体失效；蓝牙断电后的旧 disconnect 回调可能不再匹配 device。
    // Invalidate all link state; after radio power loss the old disconnect callback may no longer match device.
    reset_state(); device = nil; input = power = vibration = command = response = nil;
    pthread_mutex_lock(&stateMu); memset(&deviceInfo, 0, sizeof deviceInfo); pthread_mutex_unlock(&stateMu);
    pendingCommand = nil; awaitingAck = subscribedResponse = streamReady = sessionFailed = preferReport09 = NO;
    imuEnabled = motionCommand = NO;
    softState = NS2SoftRunning; pauseWanted = pauseStopPending = resumeCounterKnown = powerSubscribePending = NO;
    pauseStarted = resumeStarted = 0;
    deadline = linkStarted = lastRumble = reports = reports09 = rumblePackets = effectivePackets = stopPackets = 0; waitingFor = NULL; step = 0; sequence = 0;
    memset(calibration, 0, sizeof calibration);
    emit_state((ns2_state){0});
}
- (int)suspend {
    pthread_mutex_lock(&stateMu);
    BOOL canKeep = self == bridge && !terminal && streamReady && !sessionFailed && device.state == CBPeripheralStateConnected;
    if (!canKeep) { pthread_mutex_unlock(&stateMu); return 0; }
    BOOL begin = !pauseWanted;
    pauseWanted = YES; active = ready = NO; deviceInfo.ready = 0;
    memset(&latestMotion, 0, sizeof latestMotion);
    memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual); wantedMask = 0;
    if (begin) { pauseStopPending = YES; stopMask |= 3; pauseStarted = now_ns(); }
    pthread_mutex_unlock(&stateMu);
    // 后台可能冻结队列；不把冻结时间计作 ACK 失败，resume重新给在途操作有界期限。
    // Background suspension may freeze this queue; resume restarts a bounded deadline for pending work.
    deadline = 0; resumeCounterKnown = NO;
    if (softState == NS2SoftRunning || softState == NS2SoftFreshInput) softState = NS2SoftDraining;
    LOG("NS2 Pro BLE suspend mono_ms=%.3f soft=%u input_notify=%d", now_ns() / 1e6, softState, input.isNotifying);
    emit_state((ns2_state){0});
    if (self != bridge) return 1;
    emit_status(softState == NS2SoftPaused ? NS2_STATUS_PAUSED : NS2_STATUS_SUSPENDING,
        softState == NS2SoftPaused ? @"Controller link is already paused" : @"Pausing the initialized controller link");
    if (self == bridge) [self tick];
    return 1;
}
- (int)resume {
    pthread_mutex_lock(&stateMu);
    BOOL canKeep = self == bridge && !terminal && streamReady && !sessionFailed && device.state == CBPeripheralStateConnected;
    if (!canKeep) { pthread_mutex_unlock(&stateMu); return 0; }
    BOOL alreadyRunning = softState == NS2SoftRunning && ready;
    pauseWanted = NO; active = YES;
    pthread_mutex_unlock(&stateMu);
    if (!input.isNotifying) { [self fail:@"Retained report05 subscription is no longer active"]; return 0; }
    if (alreadyRunning) return 1;
    // 快速返回也先完成在途 IMU 关闭与 power 退订；input订阅始终保留，不发送重复的订阅请求。
    // Finish pending IMU disable and power unsubscription; retain input notifications without duplicate subscribe requests.
    resumeStarted = now_ns();
    LOG("NS2 Pro BLE resume mono_ms=%.3f pause_elapsed_ms=%.3f soft=%u input_notify=%d", resumeStarted / 1e6,
        pauseStarted ? (resumeStarted - pauseStarted) / 1e6 : 0, softState, input.isNotifying);
    deadline = now_ns() + 15ull * NSEC_PER_SEC;
    waitingFor = "soft resume pending operation";
    emit_status(NS2_STATUS_RESUMING, @"Resuming the retained controller link; waiting for fresh input");
    if (self == bridge) [self tick];
    return 1;
}
- (void)advanceSoftState {
    if (softState == NS2SoftDraining) {
        if (pauseStopPending || pendingCommand || awaitingAck || powerSubscribePending) return;
        if (imuEnabled) {
            uint8_t bytes[12] = {0x0c, 0x91, 1, 5, 0, 4, 0, 0, 4, 0, 0, 0};
            pendingCommand = [NSData dataWithBytes:bytes length:sizeof bytes]; motionCommand = YES;
            deadline = pauseWanted ? 0 : now_ns() + 15ull * NSEC_PER_SEC;
            waitingFor = "soft pause IMU disable write";
            return;
        }
        if (!input.isNotifying) { [self fail:@"Retained report05 subscription became inactive while pausing"]; return; }
        if (power.isNotifying) {
            softState = NS2SoftUnsubscribingPower;
            deadline = pauseWanted ? 0 : now_ns() + 15ull * NSEC_PER_SEC;
            waitingFor = "soft pause report09 unsubscribe";
            [device setNotifyValue:NO forCharacteristic:power]; return;
        }
        softState = NS2SoftPaused; deadline = 0;
        LOG("NS2 Pro BLE paused mono_ms=%.3f pause_elapsed_ms=%.3f：零包已提交，IMU已关闭，保留report05订阅但丢弃逻辑输入；power通知已退订", now_ns() / 1e6,
            pauseStarted ? (now_ns() - pauseStarted) / 1e6 : 0);
        if (pauseWanted) { emit_status(NS2_STATUS_PAUSED, @"Controller link paused; input and motion are disabled"); return; }
    }
    if (softState == NS2SoftPaused && !pauseWanted) {
        if (!input.isNotifying) { [self fail:@"Retained report05 subscription became inactive while resuming"]; return; }
        softState = NS2SoftFreshInput; preferReport09 = NO; resumeCounterKnown = NO;
        deadline = now_ns() + 15ull * NSEC_PER_SEC; waitingFor = "fresh retained report05 counter advancement after resume";
    }
}
- (void)stop {
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
    if (device && !streamReady) [central cancelPeripheralConnection:device];
    [self tick];
}
- (void)fail:(NSString *)reason {
    LOG("【红】NS2 Pro BLE：%s", reason.UTF8String);
    reset_state(); sessionFailed = YES; streamReady = NO; pendingCommand = nil; awaitingAck = NO; deadline = 0;
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    [central stopScan];
    emit_state((ns2_state){0});
    if (self != bridge) return;
    emit_status(NS2_STATUS_ERROR, reason);
    if (self != bridge) return;
    // 暂时失败显式报错；只有下一次用户扫描才允许重试，不因 ACK 超时永久封禁。
    // Report transient failures and retry only on the next user scan, without permanently rejecting a device after an ACK timeout.
    if (device) { retryAfter[device.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [central cancelPeripheralConnection:device]; }
    [self scheduleTimer];
}
- (void)telemetryFailed:(NSString *)reason {
    LOG("【红】NS2 Pro BLE 电量遥测：%s", reason.UTF8String);
    pthread_mutex_lock(&stateMu);
    ns2_decode_report09_telemetry(NULL, 0, &deviceInfo);
    ns2_decode_report09_accessories(NULL, 0, &deviceInfo);
    snprintf(deviceInfo.telemetry_error, sizeof deviceInfo.telemetry_error, "%s", reason.UTF8String);
    pthread_mutex_unlock(&stateMu);
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)manager {
    if (self != bridge) return;
    LOG("NS2 Pro BLE Bluetooth state=%ld", (long)manager.state);
    if (manager.state == CBManagerStatePoweredOn) {
        if (initialConnectionRequested) [self beginSession]; else [self scan];
        return;
    }
    if (manager.state != CBManagerStateUnknown) {
        initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
        LOG("【红】NS2 Pro BLE 不可用 state=%ld（检查蓝牙电源和应用蓝牙权限）", (long)manager.state);
        [self resetLink]; [retryAfter removeAllObjects];
        if (self != bridge) return;
        emit_status(NS2_STATUS_UNAVAILABLE, [NSString stringWithFormat:NS2Localized(@"Bluetooth unavailable (state %ld). Check Bluetooth power and permission."), (long)manager.state]);
        [self scheduleTimer];
    }
}
- (void)centralManager:(CBCentralManager *)manager didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary<NSString *, id> *)advertisement RSSI:(NSNumber *)rssi {
    if (self != bridge || !scanRequested || !manager.isScanning || device || retryAfter[peripheral.identifier].unsignedLongLongValue > now_ns()) return;
    NSData *manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey];
    const uint8_t *m = manufacturer.bytes;
    BOOL pro = manufacturer.length >= 9 && m[0] == 0x53 && m[1] == 0x05 &&
        m[5] == 0x7e && m[6] == 0x05 && m[7] == 0x69 && m[8] == 0x20;
    // 无名称模糊匹配；若广播显式携带 Pro 专属 UUID，也可作为身份依据。
    // Never match names heuristically; an explicitly advertised Pro-only UUID is also identity evidence.
    for (CBUUID *uuid in advertisement[CBAdvertisementDataServiceUUIDsKey]) pro |= uuid_is(uuid, vibrationUUID);
    if (!pro) return;
    NSNumber *connectable = advertisement[CBAdvertisementDataIsConnectable];
    if (connectable && !connectable.boolValue) return;
    [retryAfter removeObjectForKey:peripheral.identifier];
    [self connectPeripheral:peripheral name:peripheral.name ?: advertisement[CBAdvertisementDataLocalNameKey] RSSI:rssi];
}
- (void)connectPeripheral:(CBPeripheral *)peripheral name:(NSString *)name RSSI:(NSNumber *)rssi {
    if (self != bridge || device || central.state != CBManagerStatePoweredOn) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) return;
    // 断线后的异步 stop 可能晚于 resetLink；新连接握手前丢弃旧 mailbox。
    // A disconnect's asynchronous stop may follow resetLink; discard the old mailbox before a new handshake.
    reset_state();
    device = peripheral; device.delegate = self; sessionFailed = NO; [central stopScan];
    initialConnectionRequested = scanRequested = NO; scanDeadline = 0;
    pthread_mutex_lock(&stateMu);
    memset(&deviceInfo, 0, sizeof deviceInfo);
    if (name && ![name getCString:deviceInfo.name maxLength:sizeof deviceInfo.name encoding:NSUTF8StringEncoding])
        memset(deviceInfo.name, 0, sizeof deviceInfo.name);
    [peripheral.identifier.UUIDString getCString:deviceInfo.identifier maxLength:sizeof deviceInfo.identifier encoding:NSUTF8StringEncoding];
    // CoreBluetooth 用 127 表示不可用 RSSI；发现值不代表持续更新的信号强度。
    // CoreBluetooth uses 127 for unavailable RSSI; a discovery value is not a continuously updated signal reading.
    if (rssi && rssi.intValue != 127) { deviceInfo.rssi_known = 1; deviceInfo.rssi_dbm = rssi.intValue; }
    pthread_mutex_unlock(&stateMu);
    // 单独限制系统建立 BLE 链路的等待时间；GATT 发现与命令应答各自计时，不发起标准 SMP 配对。
    // Bound system BLE link establishment separately from GATT discovery and command replies, without initiating standard SMP pairing.
    linkStarted = now_ns(); deadline = linkStarted + 30ull * NSEC_PER_SEC; waitingFor = "BLE link";
    LOG("NS2 Pro BLE 连接 id=%s name=%s RSSI=%s state=%ld，链路期限30秒", peripheral.identifier.UUIDString.UTF8String, peripheral.name.UTF8String ?: "unknown", rssi ? rssi.stringValue.UTF8String : "unavailable", (long)peripheral.state);
    [central connectPeripheral:peripheral options:nil];
    [self scheduleTimer];
    emit_status(NS2_STATUS_CONNECTING, NS2Localized(@"Connecting to Switch 2 Pro"));
}
- (void)centralManager:(CBCentralManager *)manager didConnectPeripheral:(CBPeripheral *)peripheral {
    if (self != bridge || peripheral != device) return;
    LOG("NS2 Pro BLE 链路已连接，耗时 %.1f ms，开始发现服务", (now_ns() - linkStarted) / 1e6);
    pthread_mutex_lock(&stateMu); deviceInfo.connected = 1; pthread_mutex_unlock(&stateMu);
    deadline = now_ns() + 10ull * NSEC_PER_SEC; waitingFor = "service discovery";
    [peripheral discoverServices:@[[CBUUID UUIDWithString:serviceUUID]]];
    [self scheduleTimer];
    emit_status(NS2_STATUS_INITIALIZING, NS2Localized(@"Reading factory calibration and initializing rumble and player lights"));
}
- (void)centralManager:(CBCentralManager *)manager didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    LOG("【红】NS2 Pro BLE 连接失败：domain=%s code=%ld %s，耗时 %.1f ms", error.domain.UTF8String ?: "none", (long)error.code, error.localizedDescription.UTF8String ?: "未提供错误详情", (now_ns() - linkStarted) / 1e6);
    retryAfter[peripheral.identifier] = @(now_ns() + 5ull * NSEC_PER_SEC); [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_ERROR, error.localizedDescription ?: NS2Localized(@"Connection failed")); [self scheduleTimer];
}
- (void)centralManager:(CBCentralManager *)manager didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    uint64_t disconnectedAt = now_ns();
    LOG("%sNS2 Pro BLE 断开 mono_ms=%.3f soft=%u pause_elapsed_ms=%.3f domain=%s code=%ld：%s；输入和震动状态已丢弃",
        error ? "【红】" : "", disconnectedAt / 1e6, softState, pauseStarted ? (disconnectedAt - pauseStarted) / 1e6 : 0,
        error.domain.UTF8String ?: "none", (long)error.code, error.localizedDescription.UTF8String ?: "连接结束");
    [self resetLink];
    if (self != bridge) return;
    emit_status(NS2_STATUS_DISCONNECTED, error.localizedDescription ?: NS2Localized(@"Controller disconnected")); [self scheduleTimer];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (self != bridge || peripheral != device) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Service discovery failed: %@"), error.localizedDescription]]; return; }
    LOG("NS2 Pro BLE 服务发现完成，%lu 项", (unsigned long)peripheral.services.count);
    for (CBService *service in peripheral.services) if (uuid_is(service.UUID, serviceUUID)) {
        deadline = now_ns() + 10ull * NSEC_PER_SEC; waitingFor = "characteristic discovery";
        [peripheral discoverCharacteristics:@[[CBUUID UUIDWithString:inputUUID], [CBUUID UUIDWithString:powerUUID],
            [CBUUID UUIDWithString:vibrationUUID], [CBUUID UUIDWithString:commandUUID], [CBUUID UUIDWithString:responseUUID]] forService:service]; [self scheduleTimer]; return;
    }
    [self fail:NS2Localized(@"Nintendo service not found")];
}
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (self != bridge || peripheral != device || !uuid_is(service.UUID, serviceUUID)) return;
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Characteristic discovery failed: %@"), error.localizedDescription]]; return; }
    for (CBCharacteristic *ch in service.characteristics) {
        if (uuid_is(ch.UUID, inputUUID)) input = ch;
        if (uuid_is(ch.UUID, powerUUID)) power = ch;
        if (uuid_is(ch.UUID, vibrationUUID)) vibration = ch;
        if (uuid_is(ch.UUID, commandUUID)) command = ch;
        if (uuid_is(ch.UUID, responseUUID)) response = ch;
    }
    if (!input || !(input.properties & CBCharacteristicPropertyNotify) ||
        !response || !(response.properties & CBCharacteristicPropertyNotify) ||
        !command || !(command.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
        !vibration || !(vibration.properties & CBCharacteristicPropertyWriteWithoutResponse)) {
        [self fail:NS2Localized(@"The Pro rumble characteristic or required input/command properties are missing")]; return;
    }
    if ([peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse] < 42) {
        [self fail:NS2Localized(@"BLE writes without response support fewer than 42 bytes. Rumble reports cannot be split.")]; return;
    }
    LOG("NS2 Pro BLE 特征发现完成，write MTU=%lu，订阅命令响应", (unsigned long)[peripheral maximumWriteValueLengthForType:CBCharacteristicWriteWithoutResponse]);
    deadline = now_ns() + 15ull * NSEC_PER_SEC; waitingFor = "response subscription";
    [peripheral setNotifyValue:YES forCharacteristic:response]; [self scheduleTimer];
}
- (NSUInteger)initializationSteps { return 9u; }
- (NSData *)commandForStep {
    uint8_t bytes[28] = {0, 0x91, 1, 0, 0, 0, 0, 0}; size_t length = 8;
    switch (step) {
        case 0: bytes[0] = 7; bytes[3] = 1; break;
        case 1: case 2:
            bytes[0] = 2; bytes[3] = 4; bytes[5] = 8; length = 16;
            bytes[8] = 0x40; bytes[9] = 0x7e; bytes[12] = step == 1 ? 0x80 : 0xc0; bytes[13] = 0x30; bytes[14] = 1; break;
        case 3: bytes[0] = 3; bytes[3] = 0x0a; bytes[5] = 4; bytes[8] = 5; length = 12; break;
        case 4: bytes[0] = 0x0c; bytes[3] = 2; bytes[5] = 4; bytes[8] = motionCallback ? 0x2f : 0x2b; length = 12; break;
        case 5: {
            bytes[0] = 0x0a; bytes[3] = 8; bytes[5] = 20; length = 28;
            bytes[8] = 1; memset(bytes + 9, 0xff, 8); bytes[17] = 0x35; bytes[19] = 0x46; break;
        }
        case 6:
            bytes[0] = 0x0c; bytes[3] = 4; bytes[5] = 4; length = 12;
            pthread_mutex_lock(&stateMu); bytes[8] = motionCallback && motionRequested ? 0x2f : 0x2b; pthread_mutex_unlock(&stateMu);
            break;
        // 玩家1常亮；采用已公开且在冷启动有效的 09/07 bitmask 命令。
        // Player1 steady light, using the documented 09/07 bitmask command that works on cold start.
        case 7: bytes[0] = 9; bytes[3] = 7; bytes[5] = 8; bytes[8] = 1; length = 16; break;
        // 固件内置的连接成功音型，只播放一次；不建立持续震动任务。
        // Play firmware connection sample 3 once, without starting a rumble loop.
        case 8: bytes[0] = 0x0a; bytes[3] = 2; bytes[5] = 4; bytes[8] = 3; length = 12; break;
        default: return nil;
    }
    return [NSData dataWithBytes:bytes length:length];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (stopped) { [central cancelPeripheralConnection:peripheral]; return; }
    if (streamReady && ch == response) {
        if (error || !ch.isNotifying) [self fail:@"Retained command response subscription failed"];
        return;
    }
    if (ch == power && powerSubscribePending) {
        powerSubscribePending = NO;
        if (softState != NS2SoftRunning) {
            if (error || !ch.isNotifying) { [self fail:@"Pending report09 subscription failed during soft pause"]; return; }
            [self tick]; return;
        }
    }
    if (softState != NS2SoftRunning && (ch == input || ch == power)) {
        BOOL unsubscribing = softState == NS2SoftUnsubscribingPower && ch == power;
        if (!unsubscribing) { [self fail:@"Unexpected retained input/power subscription change during soft pause/resume"]; return; }
        if (error || ch.isNotifying) { [self fail:[NSString stringWithFormat:@"Soft report09 unsubscribe failed: %@", error.localizedDescription ?: @"unexpected notification state"]]; return; }
        deadline = 0;
        softState = NS2SoftDraining;
        [self tick]; return;
    }
    if (ch == power) {
        if (error || !ch.isNotifying) {
            preferReport09 = NO;
            [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 subscription failed: %@"), error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]];
        }
        return;
    }
    if (error || !ch.isNotifying) { [self fail:[NSString stringWithFormat:NS2Localized(@"Subscription to %@ failed: %@"), ch.UUID, error.localizedDescription ?: NS2Localized(@"Notifications were not enabled")]]; return; }
    if (ch == response) { LOG("NS2 Pro BLE 命令响应订阅完成，开始握手"); subscribedResponse = YES; deadline = 0; [self tick]; }
    if (ch == input) {
        streamReady = YES; deadline = 0;
        // 不发送初始零包，避免截断刚确认的连接反馈；游戏的停止请求仍走 mailbox。
        // Avoid an initial zero packet truncating the acknowledged connection feedback.
        pthread_mutex_lock(&stateMu); ready = YES; deviceInfo.ready = 1; pthread_mutex_unlock(&stateMu);
        // 仅在校准、命令 ACK 和输入订阅均成功后记住设备，发现或连接事件不写入。
        // Remember the device only after calibration, command ACKs and input subscription succeed, never on discovery or connection alone.
        [NSUserDefaults.standardUserDefaults setObject:peripheral.identifier.UUIDString forKey:lastReadyPeripheralKey];
        LOG("NS2 Pro BLE ready：工厂摇杆校准；report05%s；玩家1灯与固件反馈命令ACK；双侧双频42-byte震动，仅活动时调度；gain=%.3g（命令ACK不代表电机动作）", motionCallback ? " IMU" : "", rumbleGain);
        emit_status(NS2_STATUS_READY, NS2Localized(@"Connected: factory calibration and player 1 light initialization complete"));
        if (self != bridge) return;
        if (softState != NS2SoftRunning) { [self tick]; return; }
        // report09 订阅可能切断 report05；IMU 模式只用公开可解码的 report05。
        // Subscribing to report09 may cut off report05; IMU mode uses only the publicly decoded report05.
        if (power && !motionCallback) {
            if (power.properties & CBCharacteristicPropertyNotify) { powerSubscribePending = YES; [peripheral setNotifyValue:YES forCharacteristic:power]; }
            else [self telemetryFailed:NS2Localized(@"Report09 does not support notifications. Battery level and charging status are unavailable.")];
        }
        [self tick];
    }
}
- (void)receiveAck:(NSData *)data {
    if (!awaitingAck || data.length < 8) return;
    const uint8_t *p = data.bytes, *request = pendingCommand.bytes;
    if (p[0] != request[0] || p[3] != request[3]) return;
    if (p[1] != 1 || p[2] != 1 || (p[5] & 0x7f) != 0x78) { [self fail:NS2Localized(@"Invalid command response direction, transport or acknowledgement")]; return; }
    if (motionCommand) {
        imuEnabled = request[3] == 4;
        LOG("NS2 Pro BLE IMU %s：运行时命令已确认", imuEnabled ? "开启" : "关闭");
        motionCommand = awaitingAck = NO; pendingCommand = nil; deadline = 0;
        [self tick]; return;
    }
    if (step == 1 || step == 2) {
        if (data.length < 80 || le32(p + 8) != 0x40 || le32(p + 12) != le32(request + 12)) {
            [self fail:NS2Localized(@"The factory calibration response length or read address does not match")]; return;
        }
        ns2_calibration *cal = &calibration[step - 1]; const uint8_t *record = p + 16 + 0x28;
        unpack12(record, cal->center); unpack12(record + 3, cal->above); unpack12(record + 6, cal->below);
        for (unsigned axis = 0; axis < 2; axis++) if (!cal->center[axis] || !cal->above[axis] || !cal->below[axis] ||
            cal->center[axis] + cal->above[axis] > 4095 || cal->below[axis] > cal->center[axis]) {
            [self fail:NS2Localized(@"Factory stick calibration is invalid. Estimated centers and ranges are not used.")]; return;
        }
        LOG("NS2 Pro BLE calibration side=%lu center=%u,%u above=%u,%u below=%u,%u", (unsigned long)step - 1,
            cal->center[0], cal->center[1], cal->above[0], cal->above[1], cal->below[0], cal->below[1]);
    }
    LOG("NS2 Pro BLE ACK step=%lu cmd=%02x/%02x len=%lu", (unsigned long)step, p[0], p[3], (unsigned long)data.length);
    if (step == 6) imuEnabled = (request[8] & 4) != 0;
    step++; awaitingAck = NO; pendingCommand = nil; deadline = 0;
    if (step == [self initializationSteps]) {
        deadline = now_ns() + 5ull * NSEC_PER_SEC; waitingFor = "input subscription";
        [device setNotifyValue:YES forCharacteristic:input]; [self scheduleTimer];
    }
    else [self tick];
}
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)ch error:(NSError *)error {
    if (self != bridge || peripheral != device || sessionFailed) return;
    if (ch != response && softState != NS2SoftRunning && !(ch == input && softState == NS2SoftFreshInput)) return;
    // 开启 report09 后部分固件只持续发送此通道；必须同时解析它的真实输入布局。
    // Some firmware streams only report09 after subscription, so its actual input layout must also be decoded.
    if (ch == power) {
        if (error) { preferReport09 = NO; [self telemetryFailed:[NSString stringWithFormat:NS2Localized(@"Report09 notification read failed: %@"), error.localizedDescription]]; return; }
        NSData *powerData = ch.value;
        pthread_mutex_lock(&stateMu);
        ns2_info previous = deviceInfo;
        int valid = ns2_decode_report09_telemetry(powerData.bytes, powerData.length, &deviceInfo);
        ns2_decode_report09_accessories(powerData.bytes, powerData.length, &deviceInfo);
        ns2_info updated = deviceInfo;
        if (valid) memset(deviceInfo.telemetry_error, 0, sizeof deviceInfo.telemetry_error);
        pthread_mutex_unlock(&stateMu);
        if (previous.nfc_state_known != updated.nfc_state_known || previous.nfc_state != updated.nfc_state ||
            previous.headset_state_known != updated.headset_state_known || previous.headset_state != updated.headset_state)
            LOG("NS2 Pro BLE 附件状态：NFC known=%u raw=%u；耳机 known=%u raw=%u（仅状态，未实现读卡或音频流）",
                updated.nfc_state_known, updated.nfc_state, updated.headset_state_known, updated.headset_state);
        if (!valid) [self telemetryFailed:NS2Localized(@"Report09 is shorter than 63 bytes or its battery level is outside 0..9")];
        if (streamReady) [self publishInput:powerData report:9];
        return;
    }
    if (error) { [self fail:[NSString stringWithFormat:NS2Localized(@"Notification read failed: %@"), error.localizedDescription]]; return; }
    NSData *data = ch.value;
    if (!data) { [self fail:NS2Localized(@"Notification data is empty")]; return; }
    if (ch == response) { [self receiveAck:data]; return; }
    if (ch != input || !streamReady) return;
    if (data.length < 63) { [self fail:[NSString stringWithFormat:NS2Localized(@"Report05 has %lu bytes; at least 63 are required"), (unsigned long)data.length]]; return; }
    if (softState == NS2SoftFreshInput) {
        uint32_t counter = le32(data.bytes);
        if (!resumeCounterKnown) {
            resumeCounterKnown = YES; resumeCounter = counter;
            LOG("NS2 Pro BLE resume candidate mono_ms=%.3f counter=%u（仅建立门控基线，不发布）", now_ns() / 1e6, counter);
            return;
        }
        uint32_t delta = counter - resumeCounter;
        if (!delta || delta >= 0x80000000u || pauseWanted) return;
        softState = NS2SoftRunning; deadline = 0;
        pthread_mutex_lock(&stateMu); ready = YES; deviceInfo.ready = 1; pthread_mutex_unlock(&stateMu);
        LOG("NS2 Pro BLE resumed mono_ms=%.3f resume_elapsed_ms=%.3f：report05 counter %u -> %u，旧候选未发布", now_ns() / 1e6,
            resumeStarted ? (now_ns() - resumeStarted) / 1e6 : 0, resumeCounter, counter);
        emit_status(NS2_STATUS_READY, @"Controller link resumed with fresh input");
        if (self != bridge || softState != NS2SoftRunning) return;
        [self tick];
        if (self != bridge || softState != NS2SoftRunning) return;
        if (power && !motionCallback && (power.properties & CBCharacteristicPropertyNotify)) { powerSubscribePending = YES; [peripheral setNotifyValue:YES forCharacteristic:power]; }
    }
    pthread_mutex_lock(&stateMu);
    BOOL headsetWasKnown = deviceInfo.headset_connected_known, headsetWasConnected = deviceInfo.headset_connected;
    int valid = ns2_decode_report05_telemetry(data.bytes, data.length, &deviceInfo);
    ns2_decode_report05_accessories(data.bytes, data.length, &deviceInfo);
    BOOL headsetChanged = !headsetWasKnown || headsetWasConnected != deviceInfo.headset_connected;
    BOOL headsetConnected = deviceInfo.headset_connected;
    ns2_motion motion = {0};
    BOOL publishMotion = motionCallback && motionRequested && imuEnabled && !motionCommand && active && ready && !terminal;
    if (publishMotion && ns2_decode_report05_motion(data.bytes, data.length, &motion)) {
        // 部分固件的设备时钟不可靠；对外用接收时的单调时钟，设备值保留用于诊断。
        // Some firmware has unreliable device timestamps; export monotonic arrival time and retain the device value for diagnostics.
        motion.host_timestamp_us = now_ns() / 1000;
        latestMotion = motion;
    }
    pthread_mutex_unlock(&stateMu);
    if (headsetChanged) LOG("NS2 Pro BLE 耳机插入：%s（仅插入检测，未实现音频流）", headsetConnected ? "是" : "否");
    if (publishMotion && motion.known) motionCallback(&motion, callbackContext);
    if (self != bridge) return;
    if (!valid) {
        [self fail:NS2Localized(@"Report05 battery fields could not be decoded")]; return;
    }
    if (!preferReport09) [self publishInput:data report:5];
}
- (void)publishInput:(NSData *)data report:(unsigned)reportID {
    ns2_raw_input decoded;
    if (!ns2_decode_input_report(reportID, data.bytes, data.length, &decoded)) {
        [self fail:[NSString stringWithFormat:NS2Localized(@"Report%02x input has %lu bytes; at least 63 are required"), reportID, (unsigned long)data.length]]; return;
    }
    if (reportID == 9 && !preferReport09) {
        preferReport09 = YES;
        LOG("NS2 Pro BLE input source=report09；report05仅更新电压，避免重复输入");
    }
    uint64_t count = reportID == 9 ? ++reports09 : ++reports;
    if (count == 1 || count % 350 == 0)
        LOG("NS2 Pro BLE input report=%02x n=%llu len=%lu buttons=%llx raw=%u,%u,%u,%u",
            reportID, (unsigned long long)count, (unsigned long)data.length, (unsigned long long)decoded.buttons,
            decoded.lx, decoded.ly, decoded.rx, decoded.ry);
    // 回调在锁外调用，允许调用者在回调内停止或读取能力。
    // Invoke callbacks outside the mutex so callers may stop or query capabilities from a callback.
    pthread_mutex_lock(&stateMu);
    BOOL publish = active && ready && !terminal;
    pthread_mutex_unlock(&stateMu);
    if (publish) emit_state((ns2_state){decoded.buttons,
        calibrated_axis(decoded.lx, calibration[0], 0), calibrated_axis(decoded.ly, calibration[0], 1),
        calibrated_axis(decoded.rx, calibration[1], 0), calibrated_axis(decoded.ry, calibration[1], 1)});
}
- (void)tick {
    [self processEvents];
    [self scheduleTimer];
}
- (void)scheduleTimer {
    if (!timer || self != bridge) return;
    uint64_t now = now_ns(), next = deadline;
    if (scanDeadline && (!next || scanDeadline < next)) next = scanDeadline;
    pthread_mutex_lock(&stateMu);
    BOOL repeating = wantedMask != 0;
    if (streamReady && !sessionFailed) {
        for (unsigned side = 0; side < 2; side++)
            if ((wantedMask & (1u << side)) && (!next || wantedDeadline[side] < next)) next = wantedDeadline[side];
        if (device.canSendWriteWithoutResponse && (stopMask || repeating || (terminal && !shutdownSent))) {
            BOOL onset = (wantedMask & ~submittedMask) != 0;
            uint64_t due = stopMask || terminal || onset ? now : lastRumble + 15 * NSEC_PER_MSEC;
            if (!next || due < next) next = due;
        }
    }
    pthread_mutex_unlock(&stateMu);
    // 一次性 timer 只覆盖握手超时、扫描窗口及活动震动；无工作时永久停表。
    // A one-shot timer covers handshake deadlines, the scan window and active rumble; otherwise disarm it indefinitely.
    dispatch_time_t due = next ? dispatch_time(DISPATCH_TIME_NOW, next > now ? (int64_t)(next - now) : 0) : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(timer, due, DISPATCH_TIME_FOREVER, NSEC_PER_MSEC);
}
- (void)processEvents {
    if (self != bridge) return;
    uint64_t now = now_ns();
    if (scanDeadline && now >= scanDeadline) {
        scanRequested = NO; scanDeadline = 0;
        [central stopScan];
        emit_status(NS2_STATUS_SCAN_FINISHED, NS2Localized(@"Scan finished. Scan again to connect a Switch 2 Pro."));
        if (self != bridge) return;
    }
    if (sessionFailed) return;
    if (deadline && now >= deadline) {
        [self fail:[NSString stringWithFormat:@"Timed out waiting for %s (peripheral state %ld, command step %lu)", waitingFor ?: "initialization", (long)device.state, (unsigned long)step]];
        return;
    }
    if (!device || device.state != CBPeripheralStateConnected) return;
    pthread_mutex_lock(&stateMu); BOOL stopped = terminal; pthread_mutex_unlock(&stateMu);
    if (!streamReady) {
        if (stopped || !subscribedResponse || awaitingAck || step >= [self initializationSteps]) return;
        if (!pendingCommand) { pendingCommand = [self commandForStep]; deadline = now + NSEC_PER_SEC; waitingFor = "command write readiness"; }
        if (!device.canSendWriteWithoutResponse) return;
        [device writeValue:pendingCommand forCharacteristic:command type:CBCharacteristicWriteWithoutResponse];
        awaitingAck = YES; deadline = now + NSEC_PER_SEC; waitingFor = "command acknowledgement"; return;
    }
    if (!stopped) [self advanceSoftState];
    if (self != bridge) return;
    // IMU 只跟随游戏传感器需求；保持 report05，不启用会替代它的 report09。
    // Enable only the IMU feature bit, retaining report05 for input and motion.
    pthread_mutex_lock(&stateMu); BOOL wantsMotion = softState == NS2SoftRunning && motionCallback && motionRequested && active && !terminal; pthread_mutex_unlock(&stateMu);
    BOOL motionPhase = softState == NS2SoftRunning || softState == NS2SoftDraining;
    if (!stopped && motionPhase && motionCallback && !pauseStopPending && !awaitingAck && (pendingCommand || imuEnabled != wantsMotion)) {
        if (!pendingCommand) {
            uint8_t bytes[12] = {0x0c, 0x91, 1, wantsMotion ? 4 : 5, 0, 4, 0, 0, 4, 0, 0, 0};
            pendingCommand = [NSData dataWithBytes:bytes length:sizeof bytes]; motionCommand = YES;
            deadline = pauseWanted ? 0 : now + (softState == NS2SoftDraining ? 15ull * NSEC_PER_SEC : NSEC_PER_SEC); waitingFor = "IMU command write readiness";
        }
        if (device.canSendWriteWithoutResponse) {
            [device writeValue:pendingCommand forCharacteristic:command type:CBCharacteristicWriteWithoutResponse];
            awaitingAck = YES; deadline = pauseWanted ? 0 : now + (softState == NS2SoftDraining ? 15ull * NSEC_PER_SEC : NSEC_PER_SEC); waitingFor = "IMU command acknowledgement";
        }
    }
    pthread_mutex_lock(&stateMu);
    // 独立于菜单主线程检查租约，防止界面阻塞时重复旧震动。
    // Enforce leases independently of the UI thread so a stalled menu cannot repeat stale rumble.
    for (unsigned side = 0; side < 2; side++) {
        unsigned bit = 1u << side;
        if ((wantedMask & bit) && now >= wantedDeadline[side]) {
            wanted[side] = (ns2_vibration){0}; wantedMask &= ~bit;
            stopMask |= submittedMask & bit;
        }
    }
    BOOL urgent = stopMask != 0 || (terminal && !shutdownSent);
    BOOL onset = (wantedMask & ~submittedMask) != 0;
    BOOL repeating = wantedMask != 0;
    if (!device.canSendWriteWithoutResponse) {
        pthread_mutex_unlock(&stateMu); return;
    }
    // 静音转有效可写即发；持续活动保持15ms节奏。停止标记先发真实零包，背压只保留最新mailbox。
    // Send silent-to-active onsets when writable; sustain the 15 ms active cadence, real stop priority and latest-mailbox backpressure.
    if ((!urgent && !repeating) || (!urgent && !onset && now - lastRumble < 14 * NSEC_PER_MSEC)) {
        pthread_mutex_unlock(&stateMu); return;
    }
    ns2_vibration values[2]; memcpy(values, wanted, sizeof values);
    unsigned stopping = stopMask;
    for (unsigned side = 0; side < 2; side++) if ((stopping & (1u << side)) || !active || terminal) values[side] = (ns2_vibration){0};
    uint8_t packet[42]; ns2_encode_rumble(values, sequence, rumbleGain, packet);
    [device writeValue:[NSData dataWithBytes:packet length:sizeof packet] forCharacteristic:vibration type:CBCharacteristicWriteWithoutResponse];
    ns2_rumble_amplitudes left = ns2_rumble_amplitude_codes(values[0], rumbleGain);
    ns2_rumble_amplitudes right = ns2_rumble_amplitude_codes(values[1], rumbleGain);
    submittedMask = (left.low || left.high ? 1u : 0u) | (right.low || right.high ? 2u : 0u);
    rumblePackets++;
    if (submittedMask) effectivePackets++;
    if (stopping || terminal) stopPackets++;
    if (rumblePackets == 1 || (submittedMask && effectivePackets == 1) || rumblePackets % 64 == 0)
        LOG("NS2 Pro BLE rumble submitted=%llu effective=%llu stops=%llu requests=%llu quantizedSilent=%llu L=%.4f@%.2f/%.4f@%.2f code=%u/%u R=%.4f@%.2f/%.4f@%.2f code=%u/%u seq=%u（传输提交，非电机遥测）",
            (unsigned long long)rumblePackets, (unsigned long long)effectivePackets, (unsigned long long)stopPackets,
            (unsigned long long)rumbleRequests, (unsigned long long)quantizedSilentRequests,
            values[0].low_amp, values[0].low_freq, values[0].high_amp, values[0].high_freq, left.low, left.high,
            values[1].low_amp, values[1].low_freq, values[1].high_amp, values[1].high_freq, right.low, right.high, sequence & 15);
    memcpy(actual, values, sizeof actual); sequence++; lastRumble = now; stopMask = 0;
    BOOL continuePause = pauseStopPending;
    pauseStopPending = NO;
    if (continuePause) LOG("NS2 Pro BLE pause stop submitted mono_ms=%.3f（CoreBluetooth提交，非电机确认）", now_ns() / 1e6);
    BOOL signal = terminal && !shutdownSent;
    if (signal) shutdownSent = YES;
    pthread_mutex_unlock(&stateMu);
    if (signal) {
        LOG("NS2 Pro BLE shutdown：42-byte零包已交给 CoreBluetooth（无硬件ACK）");
        dispatch_group_leave(shutdownGroup);
    }
    if (continuePause && self == bridge) [self tick];
}
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral { if (peripheral == device) [self tick]; }
@end

int ns2_start(ns2_state_callback state, ns2_status_callback status, void *context) {
    return ns2_start_with_motion(state, status, NULL, context);
}
int ns2_rescan(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge rescan]; });
    return accepted;
}
int ns2_suspend(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge suspend]; });
    return accepted;
}
int ns2_resume(void) {
    __block int accepted = 0;
    on_queue(^{ accepted = [bridge resume]; });
    return accepted;
}
int ns2_start_with_motion(ns2_state_callback state, ns2_status_callback status, ns2_motion_callback motion, void *context) {
    __block int accepted = 0;
    on_queue(^{
        if (bridge) return;
        float gainValue = 2;
        const char *gain = getenv("NS2PRO_RUMBLE_GAIN");
        if (gain) {
            char *end; errno = 0; double parsed = strtod(gain, &end);
            if (!*gain || isspace((unsigned char)*gain) || end == gain || *end || errno || !isfinite(parsed) || parsed < 0 || parsed > 4) {
                LOG("【红】NS2PRO_RUMBLE_GAIN 必须为有限数值 0..4");
                return;
            }
            gainValue = (float)parsed;
        }
        stateCallback = state; statusCallback = status; motionCallback = motion; callbackContext = context;
        pthread_mutex_lock(&stateMu);
        terminal = NO; active = YES; ready = NO; shutdownSent = NO; wantedMask = submittedMask = stopMask = 0;
        rumbleRequests = quantizedSilentRequests = 0;
        memset(&deviceInfo, 0, sizeof deviceInfo);
        memset(&latestMotion, 0, sizeof latestMotion);
        motionRequested = motion != NULL;
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual); rumbleGain = gainValue;
        pthread_mutex_unlock(&stateMu);
        shutdownGroup = dispatch_group_create();
        bridge = [[NS2Bridge alloc] init];
        accepted = 1;
    });
    return accepted;
}
void ns2_set_motion_enabled(int enabled) {
    pthread_mutex_lock(&stateMu);
    BOOL next = enabled && !terminal;
    if (motionRequested != next) {
        motionRequested = next;
        memset(&latestMotion, 0, sizeof latestMotion);
        if (mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_set_active(int enabled) {
    on_queue(^{
        pthread_mutex_lock(&stateMu);
        BOOL next = enabled && !terminal;
        BOOL changed = active != next;
        active = next;
        if (changed) {
            memset(&latestMotion, 0, sizeof latestMotion);
            memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
            wantedMask = 0; stopMask |= submittedMask;
        }
        pthread_mutex_unlock(&stateMu);
        if (changed) { emit_state((ns2_state){0}); [bridge tick]; }
    });
}
unsigned ns2_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && active && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
unsigned ns2_device_caps(void) {
    pthread_mutex_lock(&stateMu); unsigned caps = ready && !terminal ? NS2_CAP_LEFT | NS2_CAP_RIGHT : 0;
    pthread_mutex_unlock(&stateMu); return caps;
}
void ns2_send(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq) {
    ns2_send_lease(side, low_amp, low_freq, high_amp, high_freq, 1000);
}
static ns2_vibration bounded_vibration(ns2_vibration bounded, unsigned side, unsigned duration_ms) {
    if (!isfinite(bounded.low_amp) || !isfinite(bounded.high_amp) || !isfinite(bounded.low_freq) || !isfinite(bounded.high_freq)) {
        LOG("【红】NS2 Pro BLE 拒绝非有限震动值并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    } else if ((bounded.low_amp > 0 && bounded.low_freq <= 0) || (bounded.high_amp > 0 && bounded.high_freq <= 0)) {
        LOG("【红】NS2 Pro BLE 拒绝非正载频并停止该侧 side=%u", side); bounded = (ns2_vibration){0};
    }
    bounded.low_amp = fminf(1, fmaxf(0, bounded.low_amp));
    bounded.high_amp = fminf(1, fmaxf(0, bounded.high_amp));
    bounded.low_freq = bounded.low_amp ? fminf(1252, fmaxf(40, bounded.low_freq)) : 0;
    bounded.high_freq = bounded.high_amp ? fminf(1252, fmaxf(40, bounded.high_freq)) : 0;
    if (!duration_ms) bounded = (ns2_vibration){0};
    return bounded;
}
// 调用方持有 stateMu；双侧提交共用接收时间和截止时间，更新完成后才唤醒 BLE 队列。
// The caller holds stateMu; paired sides share arrival and expiry times and wake BLE only after both updates.
static BOOL update_rumble_side_locked(unsigned side, ns2_vibration bounded, uint64_t expires) {
    unsigned bit = 1u << side;
    BOOL effective = value_effective(bounded);
    rumbleRequests++;
    if (!effective && (bounded.low_amp > 0 || bounded.high_amp > 0)) quantizedSilentRequests++;
    // 量化静音取消未提交的活动请求；只有曾提交有效幅码的侧需要停止包。
    // Quantized silence cancels unsent activity; only a side with submitted active codes needs a stop packet.
    wanted[side] = effective ? bounded : (ns2_vibration){0};
    if (effective) wantedMask |= bit; else wantedMask &= ~bit;
    wantedDeadline[side] = effective ? expires : 0;
    if (!effective) stopMask |= submittedMask & bit;
    return effective || stopMask;
}
void ns2_send_lease(unsigned side, float low_amp, float low_freq, float high_amp, float high_freq, unsigned duration_ms) {
    if (side > 1) return;
    ns2_vibration bounded = bounded_vibration((ns2_vibration){low_amp, low_freq, high_amp, high_freq}, side, duration_ms);
    if (duration_ms > 1000) duration_ms = 1000;
    pthread_mutex_lock(&stateMu);
    if (ready && active && !terminal) {
        uint64_t accepted = now_ns();
        BOOL wake = update_rumble_side_locked(side, bounded, accepted + (uint64_t)duration_ms * NSEC_PER_MSEC);
        if (wake && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_send_pair_lease(const ns2_vibration values[2], unsigned duration_ms) {
    if (!values) return;
    ns2_vibration bounded[2] = {
        bounded_vibration(values[0], 0, duration_ms),
        bounded_vibration(values[1], 1, duration_ms)
    };
    if (duration_ms > 1000) duration_ms = 1000;
    pthread_mutex_lock(&stateMu);
    if (ready && active && !terminal) {
        uint64_t accepted = now_ns(), expires = accepted + (uint64_t)duration_ms * NSEC_PER_MSEC;
        BOOL wake = update_rumble_side_locked(0, bounded[0], expires);
        wake |= update_rumble_side_locked(1, bounded[1], expires);
        if (wake && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    }
    pthread_mutex_unlock(&stateMu);
}
void ns2_actual(unsigned side, ns2_vibration *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = side < 2 ? actual[side] : (ns2_vibration){0}; pthread_mutex_unlock(&stateMu);
}
void ns2_get_info(ns2_info *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu); *out = deviceInfo; pthread_mutex_unlock(&stateMu);
}
void ns2_get_motion(ns2_motion *out) {
    if (!out) return;
    pthread_mutex_lock(&stateMu);
    *out = latestMotion;
    if (!ready || !active || !motionRequested || terminal || now_ns() / 1000 - out->host_timestamp_us > 250000)
        memset(out, 0, sizeof *out);
    pthread_mutex_unlock(&stateMu);
}
void ns2_stop_rumble(void) {
    pthread_mutex_lock(&stateMu);
    memset(wanted, 0, sizeof wanted); wantedMask = 0; stopMask |= submittedMask;
    if (stopMask && mailboxWake) dispatch_source_merge_data(mailboxWake, 1);
    pthread_mutex_unlock(&stateMu);
}
int ns2_shutdown(const char *reason, unsigned timeout_ms) {
    __block NS2Bridge *target;
    __block dispatch_group_t group;
    __block BOOL connected;
    on_queue(^{
        target = disposing ? nil : bridge;
        if (!target) return;
        pthread_mutex_lock(&stateMu);
        connected = ready;
        if (!terminal && connected) dispatch_group_enter(shutdownGroup);
        terminal = YES; active = NO; deviceInfo.ready = 0; wantedMask = 0; stopMask |= submittedMask;
        memset(wanted, 0, sizeof wanted); memset(actual, 0, sizeof actual);
        pthread_mutex_unlock(&stateMu);
        group = shutdownGroup;
        [target stop];
    });
    if (!target) return 1;
    long pending = connected ? dispatch_group_wait(group, dispatch_get_specific(&queueKey) ? DISPATCH_TIME_NOW :
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC)) : 0;
    on_queue(^{
        if (target != bridge) return;
        [target dispose]; bridge = nil;
        stateCallback = NULL; statusCallback = NULL; motionCallback = NULL; callbackContext = NULL;
    });
    LOG("%sNS2 Pro BLE shutdown reason=%s result=%s（仅传输提交，非物理电机确认）", pending ? "【红】" : "", reason ?: "unknown", pending ? "timeout" : "submitted");
    return !pending;
}
