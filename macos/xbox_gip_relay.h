// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Xbox 有线手柄 GIP 协议纯函数与启动器 → 游戏宿主本机中继协议。
//   起因：macOS 下 Chromium 系浏览器（Chrome / 115Browser / Electron 应用等）自带的 XboxDataFetcherMac
//   会对有线 Xbox USB 设备调用 USBDeviceOpen 拿走 UsbExclusiveOwner；若由每次开局起停的 s2arm-host
//   持有设备，切换游戏释放 USB 的空档会被浏览器抢占导致下一局手柄完全无响应。
//   由常驻的 S2Arm.app 启动器独占持有 USB 设备并持续唤醒 / 读 GIP 报文，通过本机 Unix 域套接字把状态
//   转给当前运行的 s2arm-host；切换游戏不释放 USB，浏览器无法插队。
#ifndef S2A_MAC_XBOX_GIP_RELAY_H
#define S2A_MAC_XBOX_GIP_RELAY_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define S2A_XBOX_GIP_RELAY_MAGIC   0x53584258u /* "SXBX" */
#define S2A_XBOX_GIP_RELAY_VERSION 1u
#define S2A_XBOX_GIP_RELAY_MAX     8

enum {
    S2A_XBOX_GIP_FLAG_CONNECTED = 1u << 0,
};

typedef struct {
    uint32_t magic;
    uint16_t version;
    uint16_t flags;      /* bit 0 (S2A_XBOX_GIP_FLAG_CONNECTED): 1 = 在线, 0 = 断开 */
    uint8_t  slot;       /* 0..S2A_XBOX_GIP_RELAY_MAX-1 */
    uint8_t  reserved[3];
    uint32_t vid;
    uint32_t pid;
    uint32_t buttons;    /* 位序同 s2a_hid_pad.buttons */
    int16_t  ax[4];      /* lx, ly, rx, ry (-32768..32767，上/右为正) */
    char     name[96];   /* USB 产品名（NUL 结尾） */
} s2a_xbox_gip_relay_packet;
_Static_assert(sizeof(s2a_xbox_gip_relay_packet) == 128, "fixed 128-byte Xbox GIP relay wire format");

static inline int s2a_xbox_gip_relay_packet_valid(const s2a_xbox_gip_relay_packet *p) {
    return p && p->magic == S2A_XBOX_GIP_RELAY_MAGIC
             && p->version == S2A_XBOX_GIP_RELAY_VERSION
             && p->slot < S2A_XBOX_GIP_RELAY_MAX;
}

static inline int s2a_xbox_gip_is_device(int vid, int pid) {
    if (vid != 0x045E) return 0;
    switch (pid) {
        case 0x02D1: /* Xbox One */
        case 0x02DD: /* Xbox One (2015) */
        case 0x02E3: /* Xbox One Elite */
        case 0x02EA: /* Xbox One S */
        case 0x0B00: /* Xbox Elite Series 2 */
        case 0x0B0A: /* Xbox Adaptive */
        case 0x0B12: /* Xbox Series X|S */
            return 1;
        default:
            return 0;
    }
}

static inline int s2a_xbox_gip_is_announce(const uint8_t *r, size_t n) {
    return r && n >= 4 && r[0] == 0x02;
}

static inline uint8_t s2a_xbox_gip_next_seq(uint8_t *seq) {
    if (!seq) return 1;
    uint8_t next = (uint8_t)(*seq + 1u);
    if (next == 0) next = 1;
    *seq = next;
    return next;
}

static inline void s2a_xbox_gip_build_power(uint8_t seq, uint8_t out[5]) {
    out[0] = 0x05;
    out[1] = 0x20;
    out[2] = seq;
    out[3] = 0x01;
    out[4] = 0x00;
}

static inline void s2a_xbox_gip_build_wake(uint8_t seq, uint8_t out[5]) {
    out[0] = 0x05;
    out[1] = 0x20;
    out[2] = seq;
    out[3] = 0x0f;
    out[4] = 0x06;
}

enum {
    S2A_XBOX_GIP_IO_OK = 0,
    S2A_XBOX_GIP_IO_RECOVER = 1,
    S2A_XBOX_GIP_IO_FATAL = 2,
};

/* 归类 USB 管道读错误：可恢复错误（pipe stall / overrun / timeout）在上限内走清 stall + 重唤醒，超限或设备拔出走致命退出 */
static inline int s2a_xbox_gip_classify_io_error(uint32_t kr, uint32_t *consecutive_recoverable, uint32_t max_recoverable) {
    if (kr == 0) {
        if (consecutive_recoverable) *consecutive_recoverable = 0;
        return S2A_XBOX_GIP_IO_OK;
    }
    /* kIOUSBPipeStalled (0xe000404f), kIOReturnOverrun (0xe00002ed),
       kIOUSBTransactionTimeout (0xe0004051), kIOReturnTimeout (0xe00002d6) */
    int recoverable = (kr == 0xe000404fu) || (kr == 0xe00002edu) ||
                      (kr == 0xe0004051u) || (kr == 0xe00002d6u);
    if (!recoverable) return S2A_XBOX_GIP_IO_FATAL;
    if (consecutive_recoverable) {
        (*consecutive_recoverable)++;
        if (*consecutive_recoverable > max_recoverable) return S2A_XBOX_GIP_IO_FATAL;
    }
    return S2A_XBOX_GIP_IO_RECOVER;
}

/* 长时间未收到任何 USB 报文时，按节流周期发一次 GIP 电源保活 / 重唤醒，防止手柄内部软复位后静默失联 */
static inline int s2a_xbox_gip_idle_should_rewake(uint64_t now_ms, uint64_t last_rx_ms, uint64_t last_rewake_ms,
                                                  uint64_t idle_threshold_ms, uint64_t rewake_interval_ms) {
    if (now_ms < last_rx_ms || now_ms - last_rx_ms < idle_threshold_ms) return 0;
    if (last_rewake_ms > 0 && now_ms >= last_rewake_ms && now_ms - last_rewake_ms < rewake_interval_ms) return 0;
    return 1;
}

static inline int s2a_xbox_gip_build_ack(const uint8_t *r, size_t n, uint8_t ack[13]) {
    if (!r || !ack || n < 3 || !(r[1] & 0x10)) return 0;
    ack[0] = 0x01;
    ack[1] = 0x20;
    ack[2] = r[2];
    ack[3] = 0x09;
    ack[4] = 0x00;
    ack[5] = r[0];
    ack[6] = 0x20;
    ack[7] = (uint8_t)(n >= 4 ? r[3] : 0);
    ack[8] = 0x00;
    ack[9] = 0x00;
    ack[10] = 0x00;
    ack[11] = 0x00;
    ack[12] = 0x00;
    return 13;
}

static inline int s2a_xbox_gip_parse_report(const uint8_t *r, size_t n, uint32_t *buttons, int16_t ax[4]) {
    if (!r || n < 14 || r[0] != 0x20) return 0;
    uint16_t xb = (uint16_t)(r[4] | (r[5] << 8));
    uint16_t lt = (uint16_t)(r[6] | (r[7] << 8));
    uint16_t rt = (uint16_t)(r[8] | (r[9] << 8));
    int16_t lx = (int16_t)(r[10] | (r[11] << 8));
    int16_t ly = (int16_t)(r[12] | (r[13] << 8));
    int16_t rx = (n >= 16) ? (int16_t)(r[14] | (r[15] << 8)) : 0;
    int16_t ry = (n >= 18) ? (int16_t)(r[16] | (r[17] << 8)) : 0;

    uint32_t b = 0;
    if (xb & 0x0010) b |= (1u << 0);   /* EAST (A) */
    if (xb & 0x0020) b |= (1u << 1);   /* SOUTH (B) */
    if (xb & 0x0040) b |= (1u << 2);   /* NORTH (X) */
    if (xb & 0x0080) b |= (1u << 3);   /* WEST (Y) */
    if (xb & 0x4000) b |= (1u << 4);   /* LSTICK */
    if (xb & 0x8000) b |= (1u << 5);   /* RSTICK */
    if (xb & 0x1000) b |= (1u << 6);   /* L */
    if (xb & 0x2000) b |= (1u << 7);   /* R */
    if (lt > 200)    b |= (1u << 8);   /* ZL */
    if (rt > 200)    b |= (1u << 9);   /* ZR */
    if (xb & 0x0004) b |= (1u << 10);  /* PLUS */
    if (xb & 0x0008) b |= (1u << 11);  /* MINUS */
    if (xb & 0x0400) b |= (1u << 12);  /* LEFT */
    if (xb & 0x0100) b |= (1u << 13);  /* UP */
    if (xb & 0x0800) b |= (1u << 14);  /* RIGHT */
    if (xb & 0x0200) b |= (1u << 15);  /* DOWN */

    if (buttons) *buttons = b;
    if (ax) {
        ax[0] = lx; ax[1] = ly; ax[2] = rx; ax[3] = ry;
    }
    return 1;
}

static inline int s2a_xbox_gip_write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static inline int s2a_xbox_gip_read_exact(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, p + got, len - got);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        got += (size_t)n;
    }
    return 0;
}

#if defined(__APPLE__) && defined(S2A_XBOX_GIP_IOKIT)
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

static inline int s2a_xbox_usb_has_hid_child(io_service_t dev) {
    if (!dev) return 0;
    io_iterator_t iter = 0;
    kern_return_t kr = IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &iter);
    if (kr != KERN_SUCCESS || !iter) return 0;
    io_registry_entry_t child = 0;
    int has_hid = 0;
    while ((child = IOIteratorNext(iter)) != 0) {
        if (IOObjectConformsTo(child, "IOHIDInterface") || IOObjectConformsTo(child, "IOHIDDevice")) {
            has_hid = 1;
            IOObjectRelease(child);
            break;
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(iter);
    return has_hid;
}

/* 读取 USB 设备或其子接口上的 UsbExclusiveOwner 属性（如 "pid 1414, 115Browser"）；读不到时写空串并返回 0 */
static inline int s2a_xbox_usb_exclusive_owner(io_service_t dev, char *out, size_t out_sz) {
    if (!out || out_sz == 0) return 0;
    out[0] = '\0';
    if (!dev) return 0;
    CFTypeRef prop = IORegistryEntryCreateCFProperty(dev, CFSTR("UsbExclusiveOwner"), kCFAllocatorDefault, 0);
    if (prop) {
        int ok = (CFGetTypeID(prop) == CFStringGetTypeID()) &&
                 CFStringGetCString((CFStringRef)prop, out, (CFIndex)out_sz, kCFStringEncodingUTF8) &&
                 out[0] != '\0';
        CFRelease(prop);
        if (ok) return 1;
    }
    io_iterator_t iter = 0;
    if (IORegistryEntryCreateIterator(dev, kIOServicePlane, kIORegistryIterateRecursively, &iter) != KERN_SUCCESS || !iter) return 0;
    io_registry_entry_t child = 0;
    int found = 0;
    while ((child = IOIteratorNext(iter)) != 0) {
        CFTypeRef cp = IORegistryEntryCreateCFProperty(child, CFSTR("UsbExclusiveOwner"), kCFAllocatorDefault, 0);
        if (cp) {
            if (CFGetTypeID(cp) == CFStringGetTypeID() &&
                CFStringGetCString((CFStringRef)cp, out, (CFIndex)out_sz, kCFStringEncodingUTF8) &&
                out[0] != '\0') {
                found = 1;
            }
            CFRelease(cp);
        }
        IOObjectRelease(child);
        if (found) break;
    }
    IOObjectRelease(iter);
    return found;
}
#endif

#endif
