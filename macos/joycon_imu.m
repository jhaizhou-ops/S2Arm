// Joy-Con / Pro Controller：IOHID 直读六轴 + 双人按键/摇杆（macOS GameController 对 Joy-Con 常不暴露或不合双槽）。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#include "joycon_imu.h"
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <mach/mach_time.h>

enum { JC_L = 0, JC_R = 1, JC_N = 2 };
enum { JC_PID_L = 0x2006, JC_PID_R = 0x2007, JC_PID_PRO = 0x2009 };

typedef struct {
    IOHIDDeviceRef device;
    uint8_t *report_buf;
    uint8_t pkt;
    int slot;                 // JC_L / JC_R
    int product_id;
    s2a_pad_motion sample;
    int known;
    uint32_t buttons;         // ns2 16 源码位
    int32_t sticks[4];
    int pad_known;
} jc_dev;

static IOHIDManagerRef g_mgr;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static jc_dev g_dev[JC_N];
static _Atomic int g_want_imu;
static _Atomic int g_want_pad;
static int g_started;
static uint8_t g_pkt_global;

static int16_t rd16(const uint8_t *p) { return (int16_t)(p[0] | (p[1] << 8)); }

static uint64_t now_us(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / (tb.denom * 1000ull);
}

static void send_sub(jc_dev *d, uint8_t cmd, uint8_t arg) {
    if (!d->device) return;
    uint8_t report[0x40];
    memset(report, 0, sizeof report);
    report[0] = 0x01;
    report[1] = (d->pkt++ & 0x0f);
    report[2] = 0x00; report[3] = 0x01; report[4] = 0x00; report[5] = 0x40;
    report[6] = 0x00; report[7] = 0x01; report[8] = 0x00; report[9] = 0x40;
    report[10] = cmd;
    report[11] = arg;
    IOHIDDeviceSetReport(d->device, kIOHIDReportTypeOutput, 0x01, report, sizeof report);
}

static void decode_imu(int slot, int product_id, const uint8_t *s, s2a_pad_motion *out) {
    float ax = rd16(s + 0) * 0.000244f;
    float ay = rd16(s + 2) * 0.000244f;
    float az = rd16(s + 4) * 0.000244f;
    float gx = rd16(s + 6) * 0.06103f;
    float gy = rd16(s + 8) * 0.06103f;
    float gz = rd16(s + 10) * 0.06103f;
    if (product_id == JC_PID_L) {
        out->acceleration_x = ay; out->acceleration_y = -ax; out->acceleration_z = az;
        out->gyro_x = gy; out->gyro_y = -gx; out->gyro_z = gz;
    } else {
        out->acceleration_x = -ay; out->acceleration_y = ax; out->acceleration_z = az;
        out->gyro_x = -gy; out->gyro_y = gx; out->gyro_z = gz;
    }
    (void)slot;
    out->host_timestamp_us = now_us();
}

// 12-bit 摇杆 → ±32767（中位约 2048）
static int32_t axis12(uint16_t raw) {
    int v = ((int)raw - 2048) * 16;
    if (v > 32767) v = 32767;
    if (v < -32767) v = -32767;
    return (int32_t)v;
}

static uint16_t stick_x(const uint8_t *p) { return (uint16_t)(p[0] | ((p[1] & 0x0f) << 8)); }
static uint16_t stick_y(const uint8_t *p) { return (uint16_t)((p[1] >> 4) | (p[2] << 4)); }

enum {
    B_EAST = 1u << 0, B_SOUTH = 1u << 1, B_NORTH = 1u << 2, B_WEST = 1u << 3,
    B_LS = 1u << 4, B_RS = 1u << 5, B_L = 1u << 6, B_R = 1u << 7,
    B_ZL = 1u << 8, B_ZR = 1u << 9, B_MENU = 1u << 10, B_OPT = 1u << 11,
    B_DL = 1u << 12, B_DU = 1u << 13, B_DR = 1u << 14, B_DD = 1u << 15,
};

// 每只 Joy-Con → 一只玩家手柄：报物理键/摇杆；SL/SR 并进 L/R。横握由游戏 HoldType 解释（勿在 HID 里预转面键）。
static void decode_pad(int product_id, const uint8_t *b, const uint8_t *lstick, const uint8_t *rstick,
                       uint32_t *buttons, int32_t sticks[4]) {
    uint32_t out = 0;
    int32_t lx = 0, ly = 0, rx = 0, ry = 0;
    uint8_t b0 = b[0], b1 = b[1], b2 = b[2];

    if (product_id == JC_PID_PRO) {
        if (b0 & 0x01) out |= B_WEST;    // Y
        if (b0 & 0x02) out |= B_NORTH;   // X
        if (b0 & 0x04) out |= B_SOUTH;   // B
        if (b0 & 0x08) out |= B_EAST;    // A
        if (b0 & 0x40) out |= B_R;
        if (b0 & 0x80) out |= B_ZR;
        if (b1 & 0x01) out |= B_OPT;     // Minus
        if (b1 & 0x02) out |= B_MENU;    // Plus
        if (b1 & 0x04) out |= B_RS;
        if (b1 & 0x08) out |= B_LS;
        if (b2 & 0x01) out |= B_DD;
        if (b2 & 0x02) out |= B_DU;
        if (b2 & 0x04) out |= B_DR;
        if (b2 & 0x08) out |= B_DL;
        if (b2 & 0x40) out |= B_L;
        if (b2 & 0x80) out |= B_ZL;
        lx = axis12(stick_x(lstick)); ly = axis12(stick_y(lstick));
        rx = axis12(stick_x(rstick)); ry = axis12(stick_y(rstick));
        // Joy-Con/Pro HID Y 轴与常见 GC 相反
        ly = -ly; ry = -ry;
    } else if (product_id == JC_PID_L) {
        // 左柄横握：物理十字键落在屏上 ABXY 位置（下=A 确认、左=B、右=X、上=Y）。
        // 若仍报 D-pad，选角色等 UI 会当成方向键、无法确认。SL/SR → L/R。
        if (b2 & 0x01) out |= B_EAST;   // Down → A
        if (b2 & 0x04) out |= B_SOUTH;  // Right → B
        if (b2 & 0x02) out |= B_NORTH;  // Up → X
        if (b2 & 0x08) out |= B_WEST;   // Left → Y
        if (b2 & 0x40) out |= B_L;       // L
        if (b2 & 0x80) out |= B_ZL;      // ZL
        if (b2 & 0x20) out |= B_L;       // SL → L
        if (b2 & 0x10) out |= B_R;       // SR → R
        if (b1 & 0x01) out |= B_OPT;     // Minus
        if (b1 & 0x08) out |= B_LS;
        if (b1 & 0x20) out |= B_MENU;    // Capture → Plus 位（无独立 Capture 目标）
        int32_t sx = axis12(stick_x(lstick)), sy = -axis12(stick_y(lstick));
        lx = sx; ly = sy;                // JoyLeft → AnalogStickL
    } else {
        // 右柄：报物理面键 / R / ZR / Plus；JoyRight 摇杆在 AnalogStickR。
        // 横握时玩家按「屏上确认」= 物理 X，游戏 HoldType=Horizontal 自己把 X 当 A。
        if (b0 & 0x08) out |= B_EAST;    // A
        if (b0 & 0x04) out |= B_SOUTH;   // B
        if (b0 & 0x02) out |= B_NORTH;   // X
        if (b0 & 0x01) out |= B_WEST;    // Y
        if (b0 & 0x40) out |= B_R;       // R
        if (b0 & 0x80) out |= B_ZR;      // ZR
        if (b0 & 0x20) out |= B_L;       // SL → L
        if (b0 & 0x10) out |= B_R;       // SR → R
        if (b1 & 0x02) out |= B_MENU;    // Plus
        if (b1 & 0x04) out |= B_RS;
        if (b1 & 0x10) out |= B_OPT;     // Home → Minus 位（无独立 Home 目标）
        int32_t sx = axis12(stick_x(rstick)), sy = -axis12(stick_y(rstick));
        rx = sx; ry = sy;                // JoyRight → AnalogStickR
    }
    *buttons = out;
    sticks[0] = lx; sticks[1] = ly; sticks[2] = rx; sticks[3] = ry;
}

static void apply_report(jc_dev *d, uint32_t report_id, const uint8_t *report, CFIndex len) {
    if (report_id != 0x30 || !d) return;
    int off = (len > 0 && report[0] == 0x30) ? 1 : 0;
    if (len - off < 48) return;
    const uint8_t *body = report + off;
    // body: timer, batt, buttons[3], lstick[3], rstick[3], ... imu@36
    const uint8_t *btns = body + 2;
    const uint8_t *lstick = body + 5;
    const uint8_t *rstick = body + 8;
    const uint8_t *s = body + 36;

    s2a_pad_motion m = {0};
    decode_imu(d->slot, d->product_id, s, &m);
    uint32_t buttons = 0;
    int32_t sticks[4] = {0};
    decode_pad(d->product_id, btns, lstick, rstick, &buttons, sticks);

    pthread_mutex_lock(&g_mu);
    d->sample = m;
    d->known = 1;
    d->buttons = buttons;
    memcpy(d->sticks, sticks, sizeof sticks);
    d->pad_known = 1;
    pthread_mutex_unlock(&g_mu);
}

static void report_cb(void *context, IOReturn result, void *sender, IOHIDReportType type,
                      uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)result; (void)sender; (void)type;
    apply_report((jc_dev *)context, reportID, report, reportLength);
}

static int slot_for_pid(int pid) {
    if (pid == JC_PID_L) return JC_L;
    if (pid == JC_PID_R || pid == JC_PID_PRO) return JC_R;
    return -1;
}

static int full_report_wanted(void) {
    return atomic_load(&g_want_imu) || atomic_load(&g_want_pad);
}

static void apply_mode_locked(void) {
    int full = full_report_wanted();
    for (int i = 0; i < JC_N; i++) {
        jc_dev *d = &g_dev[i];
        if (!d->device) continue;
        if (full) {
            if (atomic_load(&g_want_imu)) send_sub(d, 0x40, 1);
            send_sub(d, 0x03, 0x30);
        } else {
            send_sub(d, 0x40, 0);
            send_sub(d, 0x03, 0x3f);
            d->known = 0;
            d->pad_known = 0;
            memset(&d->sample, 0, sizeof d->sample);
            d->buttons = 0;
            memset(d->sticks, 0, sizeof d->sticks);
        }
    }
}

static void attach_device(IOHIDDeviceRef device) {
    CFNumberRef pid_cf = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
    int pid = 0;
    if (pid_cf) CFNumberGetValue(pid_cf, kCFNumberIntType, &pid);
    int slot = slot_for_pid(pid);
    if (slot < 0) return;

    pthread_mutex_lock(&g_mu);
    jc_dev *d = &g_dev[slot];
    if (d->device == device) { pthread_mutex_unlock(&g_mu); return; }
    if (d->device) {
        IOHIDDeviceRegisterInputReportCallback(d->device, d->report_buf, 0x200, NULL, NULL);
        IOHIDDeviceClose(d->device, kIOHIDOptionsTypeNone);
        free(d->report_buf);
        memset(d, 0, sizeof *d);
    }
    if (IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        pthread_mutex_unlock(&g_mu);
        return;
    }
    d->device = device;
    d->product_id = pid;
    d->slot = slot;
    d->pkt = g_pkt_global++;
    d->report_buf = calloc(1, 0x200);
    IOHIDDeviceRegisterInputReportCallback(device, d->report_buf, 0x200, report_cb, d);
    int want = full_report_wanted();
    pthread_mutex_unlock(&g_mu);

    if (want) {
        if (atomic_load(&g_want_imu)) send_sub(d, 0x40, 1);
        send_sub(d, 0x03, 0x30);
        fprintf(stderr, "[输入] Joy-Con HID：已接通 %s（shared%s）\n",
                pid == JC_PID_L ? "L" : (pid == JC_PID_PRO ? "Pro" : "R"),
                atomic_load(&g_want_pad) ? "，双人按键" : "");
    }
}

static void detach_device(IOHIDDeviceRef device) {
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < JC_N; i++) {
        jc_dev *d = &g_dev[i];
        if (d->device != device) continue;
        IOHIDDeviceRegisterInputReportCallback(d->device, d->report_buf, 0x200, NULL, NULL);
        IOHIDDeviceClose(d->device, kIOHIDOptionsTypeNone);
        free(d->report_buf);
        memset(d, 0, sizeof *d);
    }
    pthread_mutex_unlock(&g_mu);
}

static void match_cb(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    attach_device(device);
}

static void remove_cb(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    (void)context; (void)result; (void)sender;
    detach_device(device);
}

static void ensure_manager(void) {
    if (g_started) return;
    g_started = 1;
    g_mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *match = @[
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_L)},
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_R)},
        @{@kIOHIDVendorIDKey: @0x057e, @kIOHIDProductIDKey: @(JC_PID_PRO)},
    ];
    IOHIDManagerSetDeviceMatchingMultiple(g_mgr, (__bridge CFArrayRef)match);
    IOHIDManagerRegisterDeviceMatchingCallback(g_mgr, match_cb, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(g_mgr, remove_cb, NULL);
    IOHIDManagerScheduleWithRunLoop(g_mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(g_mgr, kIOHIDOptionsTypeNone);
    NSSet *devs = CFBridgingRelease(IOHIDManagerCopyDevices(g_mgr));
    for (id obj in devs) attach_device((__bridge IOHIDDeviceRef)obj);
}

void s2a_joycon_imu_set_enabled(int enabled) {
    ensure_manager();
    int on = enabled ? 1 : 0;
    int prev = atomic_exchange(&g_want_imu, on);
    if (prev == on) return;
    pthread_mutex_lock(&g_mu);
    apply_mode_locked();
    pthread_mutex_unlock(&g_mu);
    if (on) fprintf(stderr, "[输入] Joy-Con HID 六轴：开启（GameController 无 motion 时的回退）\n");
    else fprintf(stderr, "[输入] Joy-Con HID 六轴：关闭\n");
}

void s2a_joycon_pad_ensure(void) {
    ensure_manager();
    int prev = atomic_exchange(&g_want_pad, 1);
    if (prev) return;
    pthread_mutex_lock(&g_mu);
    apply_mode_locked();
    pthread_mutex_unlock(&g_mu);
    fprintf(stderr, "[输入] Joy-Con HID 按键：开启（L/R 各一玩家，真实双人）\n");
}

int s2a_joycon_imu_read(s2a_pad_motion *out_l, s2a_pad_motion *out_r) {
    int mask = 0;
    pthread_mutex_lock(&g_mu);
    if (g_dev[JC_L].known) {
        if (out_l) *out_l = g_dev[JC_L].sample;
        mask |= 1;
    }
    if (g_dev[JC_R].known) {
        if (out_r) *out_r = g_dev[JC_R].sample;
        mask |= 2;
    }
    pthread_mutex_unlock(&g_mu);
    return mask;
}

int s2a_joycon_pad_count(void) {
    int n = 0;
    pthread_mutex_lock(&g_mu);
    if (g_dev[JC_L].pad_known && g_dev[JC_L].device) n++;
    if (g_dev[JC_R].pad_known && g_dev[JC_R].device) n++;
    // 已连接但还没收到第一帧：仍按设备在位计（避免起局瞬间 pads=1 关第二槽）
    if (!n) {
        if (g_dev[JC_L].device) n++;
        if (g_dev[JC_R].device) n++;
    }
    pthread_mutex_unlock(&g_mu);
    return n > 2 ? 2 : n;
}

int s2a_joycon_pad_read(int slot, uint32_t *buttons, int32_t sticks[4]) {
    if (slot < 0 || slot > 1 || !buttons || !sticks) return 0;
    pthread_mutex_lock(&g_mu);
    // 只有一只时：优先有数据的那只放到 slot0
    int idx = slot;
    if (!g_dev[JC_L].device && g_dev[JC_R].device) {
        idx = (slot == 0) ? JC_R : -1;
    } else if (g_dev[JC_L].device && !g_dev[JC_R].device) {
        idx = (slot == 0) ? JC_L : -1;
    } else {
        idx = slot; // 0=L 1=R
    }
    if (idx < 0 || !g_dev[idx].device) {
        pthread_mutex_unlock(&g_mu);
        return 0;
    }
    *buttons = g_dev[idx].buttons;
    memcpy(sticks, g_dev[idx].sticks, sizeof g_dev[idx].sticks);
    int ok = g_dev[idx].pad_known || g_dev[idx].device != NULL;
    pthread_mutex_unlock(&g_mu);
    return ok ? 1 : 0;
}
