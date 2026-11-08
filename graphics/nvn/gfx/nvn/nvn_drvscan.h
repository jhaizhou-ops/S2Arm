// The NVN API version the game's own driver reports, read out of that driver: it is linked into the sdk module, and its nvnDeviceGetInteger is a switch over
// the device-info items whose cases 0 / 1 return the API major / minor as immediates. Games compare against the version of the headers they were built with,
// some for exact equality (Raiden V Director's Cut, SDK 6.5: main+0x173914 requires 53 and 310 exactly and asserts otherwise; the SDK-based guess said 53.313).
// Shape, the same in every SDK checked (4.4 to 20.5): cmp wI, #items ; b.hi default ; <jump table dispatch> ; movz w0, #major ; br xT, with case 1's target
// starting movz w0, #minor. Dispatch is either adrp/add T ; ldrsw xE, [T, xI, lsl #2] ; add xT, xE, T (entry = T + s32) or adrp/add T ; adr L ; ldrb / ldrh
// wE, [T, xI(, lsl #1)] ; add xT, L, xE, lsl #2 (entry = L + 4 * u8 / u16). img = the module image (offset 0 = base, page-aligned), text = [0, text_end).
// nvn_drv_items_scan: every case of that switch whose target is movz w0, #imm gives items[case] = imm (−1: the case computes its value, reads the device, or is out of range);
//   items[0] is the major (preset before the branch). Returns the number of cases on exactly one match with major 53 or 55 (two matches with the same table count as one); 0 otherwise.
//   11-02 Mario + Rabbids Sparks of Hope (SDK 13.3.5): its driver reports the newest GPU code version as 1.16 (items 0x2E / 0x30), the host's SMO-era table said 1.14, and the game
//   checks each of its 1120 shaders against that range: the compute shader for Quarter Depth was refused, its resource stayed null and main+0x963c28 read it.
// nvn_drv_api_scan: items 0 / 1 (the API version); returns 1 and fills api[] on a match
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline uint32_t drv_w(const uint8_t *img, size_t o) { uint32_t w; memcpy(&w, img + o, 4); return w; }
static inline int64_t drv_sx(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }
// orr w0, wzr, #bitmask (the logical-immediate alias of mov w0, #imm; 32-bit, N = 0) → its value; not that instruction → -1. Drivers load some constants this way:
//   Super Mario Party / GRID Autosport (driver 53.312) return 1 for the GPU code version majors (0x320003e0) and 16 for the newest minor (0x321c03e0), which a movz-only scan read
//   as -1, so the host reported its table's 1.14 and the game's own GLSLC (1.16 / 1.15) failed the game's range check before any compile (Super Mario Party asserted at main+0x82cc70)
static inline int32_t drv_orr_w0(uint32_t m) {
    if ((m & 0xffc003ff) != 0x320003e0) return -1;
    unsigned immr = (m >> 16) & 0x3f, imms = (m >> 10) & 0x3f, len = 5;
    while (len && !((~imms >> len) & 1)) len--;   // element size 2^len: the highest clear bit of imms (N = 0)
    if (!len) return -1;
    unsigned e = 1u << len, s = imms & (e - 1), r = immr & (e - 1);
    if (s == e - 1) return -1;   // all ones in the element: reserved
    uint64_t el = (1ull << (s + 1)) - 1; el = (r ? ((el >> r) | (el << (e - r))) : el) & ((e == 64 ? 0 : 1ull << e) - 1);
    uint32_t v = 0; for (unsigned k = 0; k < 32; k += e) v |= (uint32_t)el << k;
    return (int32_t)v;
}
static inline int nvn_drv_items_scan(const uint8_t *img, size_t text_end, size_t size, int32_t *items, int nmax) {
    int found = 0; static int32_t cur[256];
    for (size_t o = 32; o + 8 <= text_end; o += 4) {
        uint32_t mv = drv_w(img, o), br = drv_w(img, o + 4);
        if ((mv & 0xffe0001f) != 0x52800000 || (br & 0xfffffc1f) != 0xd61f0000) continue;   // movz w0, #imm ; br xT
        int major = (int)((mv >> 5) & 0xffff);
        if (major != 53 && major != 55) continue;
        size_t cmp = 0; for (size_t k = 4; k <= 9 * 4 && k <= o; k += 4) {
            uint32_t c = drv_w(img, o - k), b = drv_w(img, o - k + 4);
            if ((c & 0xffc0001f) == 0x7100001f && (b & 0xff00001f) == 0x54000008) { cmp = o - k; break; }   // cmp wI, #items ; b.hi
        }
        if (!cmp) continue;
        int ncase = (int)((drv_w(img, cmp) >> 10) & 0xfff) + 1;
        if (ncase < 2 || ncase > 256) continue;
        int64_t T = -1, L = -1; int kind = 0;   // 1 ldrsw (T-relative), 2 ldrb, 3 ldrh (L-relative)
        for (size_t p = cmp + 8; p < o; p += 4) {
            uint32_t w = drv_w(img, p);
            if ((w & 0x9f000000) == 0x90000000 && p + 4 < o) {   // adrp ; add
                uint32_t a = drv_w(img, p + 4); if ((a & 0xffc00000) != 0x91000000) continue;
                T = (int64_t)(p & ~(size_t)0xfff) + (drv_sx(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21) << 12) + ((a >> 10) & 0xfff);
            } else if ((w & 0x9f000000) == 0x10000000) L = (int64_t)p + drv_sx(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21);   // adr
            else if ((w & 0xffe0fc00) == 0xb8a07800) kind = 1;
            else if ((w & 0xffe0fc00) == 0x38606800) kind = 2;
            else if ((w & 0xffe0fc00) == 0x78607800) kind = 3;
        }
        if (T < 0 || !kind || (kind > 1 && L < 0)) continue;
        size_t esz = kind == 1 ? 4 : kind == 2 ? 1 : 2;
        if ((uint64_t)T + esz * (uint64_t)ncase > size) continue;
        for (int i = 0; i < ncase; i++) {
            int64_t t;
            if (kind == 1) { int32_t e; memcpy(&e, img + T + 4 * i, 4); t = T + e; }
            else if (kind == 2) t = L + 4 * (int64_t)img[T + i];
            else { uint16_t e; memcpy(&e, img + T + 2 * i, 2); t = L + 4 * (int64_t)e; }
            if (t < 0 || (uint64_t)t + 4 > text_end) { cur[i] = -1; continue; }
            uint32_t m = drv_w(img, (size_t)t);
            cur[i] = (m & 0xffe0001f) == 0x52800000 ? (int32_t)((m >> 5) & 0xffff) : drv_orr_w0(m);
        }
        if (cur[1] < 0) continue;   // case 1 must return the minor as an immediate (this is the version switch)
        cur[0] = major;
        if (found && (found != ncase || memcmp(items, cur, sizeof *cur * (size_t)(ncase < nmax ? ncase : nmax)))) return 0;
        found = ncase; for (int i = 0; i < nmax; i++) items[i] = i < ncase ? cur[i] : -1;
    }
    return found;
}
static inline int nvn_drv_api_scan(const uint8_t *img, size_t text_end, size_t size, int api[2]) {
    int32_t it[2]; if (!nvn_drv_items_scan(img, text_end, size, it, 2)) return 0;
    api[0] = it[0]; api[1] = it[1]; return 1;
}
// nvn_drv_nvrm_rgba8_scan: the NvColorFormat the game's own driver gives an RGBA8 texture in nvnTextureGetNvRmSurfaceNVX (its default case). NvRm changed the encoding twice and the
//   game's VIC library accepts only its own: 0x1_0053_2120 in drivers 6.4–10.9, 0x2_0053_2120 in 11.4–14.3 (colour space renumbered: every format's bits 32 and up + 1, R8 0xE… → 0xF…),
//   0x2_00A6_2120 in 15.3–20.5 (the field at bits 16–31 one bit higher: 0x0053 → 0x00A6, R8's 0x0920 → 0x1240); checked against 32 games' sdk modules, SDK 4.4 to 20.5.
//   11-03 DRAGON QUEST X Offline (SDK 13.3): its movie player blits each frame into an NVN texture with NvBlit, NvDdkVicConfigureTargetSurface rejected the host's 0x1_00D1_2120
//   (BGRA8) as NvError_NotSupported (2), GetOutputBuffer returned 0x100e and the game asserted (Break at sdk+0x3ccf00).
//   The function is found by its name: the driver's GetProcAddress compares against "nvnTextureGetNvRmSurfaceNVX" (adrp / add of the string, cbz w0 to the match) and the match
//   loads the function (adrp / ldr of its GOT slot, already relocated in a loaded module, so the slot holds base + offset; or adr, alone or after a nop, SDK 16 and later); a leading b
//   (the argument-swapping thunk) is followed. In its first 64 instructions the first movz xN, #0x2120 with movk xN, #M, lsl 16 and movk xN, #K, lsl 32 within the next 9 (either
//   order) gives K << 32 | M << 16 | 0x2120. Returns that when every reference to the name agrees; 0 when the name, the function or the constant is not there (SDK 4.x builds it
//   differently) or two references disagree.
static inline int64_t drv_adr_target(uint32_t w, size_t pc) { return (int64_t)pc + drv_sx(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21); }
static inline int64_t drv_adrp_page(uint32_t w, size_t pc) { return (int64_t)(pc & ~(size_t)0xfff) + (drv_sx(((w >> 29) & 3) | (((w >> 5) & 0x7ffff) << 2), 21) << 12); }
static inline uint64_t nvn_drv_nvrm_rgba8_scan(const uint8_t *img, size_t text_end, size_t size, uint64_t base) {
    static const char name[] = "nvnTextureGetNvRmSurfaceNVX";
    int64_t s = -1;
    for (size_t o = 0; o + sizeof name <= size; o++) if (img[o] == 'n' && !memcmp(img + o, name, sizeof name)) { s = (int64_t)o; break; }
    if (s < 0) return 0;
    uint64_t found = 0;
    for (size_t o = 0; o + 8 <= text_end; o += 4) {
        uint32_t w = drv_w(img, o), a = drv_w(img, o + 4);
        if ((w & 0x9f000000) != 0x90000000 || drv_adrp_page(w, o) != (s & ~(int64_t)0xfff)) continue;
        if ((a & 0xffc00000) != 0x91000000 || ((a >> 10) & 0xfff) != (uint32_t)(s & 0xfff) || ((a >> 5) & 31) != (w & 31)) continue;   // add xR, xR, #lo
        int64_t t = -1;
        for (size_t p = o + 8; p < o + 8 + 6 * 4 && p + 4 <= text_end; p += 4) {
            uint32_t c = drv_w(img, p);
            if ((c & 0xff00001f) == 0x34000000) { t = (int64_t)p + drv_sx((c >> 5) & 0x7ffff, 19) * 4; break; }   // cbz w0, match
        }
        if (t < 0 || (uint64_t)t + 8 > text_end) continue;
        uint32_t m0 = drv_w(img, (size_t)t), m1 = drv_w(img, (size_t)t + 4); int64_t f = -1;
        if ((m0 & 0x9f00001f) == 0x10000000) f = drv_adr_target(m0, (size_t)t);   // adr x0, f
        else if (m0 == 0xd503201f && (m1 & 0x9f00001f) == 0x10000000) f = drv_adr_target(m1, (size_t)t + 4);   // nop ; adr x0, f
        else if ((m0 & 0x9f00001f) == 0x90000000 && (m1 & 0xffc003ff) == 0xf9400000) {   // adrp x0 ; ldr x0, [x0, #slot]
            int64_t slot = drv_adrp_page(m0, (size_t)t) + (int64_t)((m1 >> 10) & 0xfff) * 8; uint64_t v;
            if (slot < 0 || (uint64_t)slot + 8 > size) continue;
            memcpy(&v, img + slot, 8); f = (int64_t)(v - base);
        }
        if (f < 0 || (uint64_t)f + 4 > text_end || (f & 3)) continue;
        for (int k = 0; k < 4 && (uint64_t)f + 4 * (k + 1) <= text_end; k++) {   // the thunk: mov x1, x0 ; mov x0, x2 ; b body
            uint32_t b = drv_w(img, (size_t)f + 4 * (size_t)k);
            if ((b >> 26) == 0x05) { f = f + 4 * k + drv_sx(b & 0x3ffffff, 26) * 4; break; }
        }
        uint64_t cf = 0;
        for (int k = 0; k < 64 && f >= 0 && (uint64_t)f + 4 * (k + 1) <= text_end; k++) {
            uint32_t z = drv_w(img, (size_t)f + 4 * (size_t)k);
            if ((z & 0xffffffe0) != 0xd2842400) continue;   // movz xN, #0x2120
            uint32_t rd = z & 31; int64_t mid = -1, hi = -1;
            for (int j = 1; j <= 9 && (uint64_t)f + 4 * (k + j + 1) <= text_end; j++) {
                uint32_t q = drv_w(img, (size_t)f + 4 * (size_t)(k + j));
                if ((q & 0xffe0001f) == (0xf2a00000u | rd) && mid < 0) mid = (q >> 5) & 0xffff;   // movk xN, #M, lsl 16
                else if ((q & 0xffe0001f) == (0xf2c00000u | rd) && hi < 0) hi = (q >> 5) & 0xffff;   // movk xN, #K, lsl 32
            }
            if (mid >= 0 && hi >= 0) cf = (uint64_t)hi << 32 | (uint64_t)mid << 16 | 0x2120;
            break;
        }
        if (!cf) continue;
        if (found && found != cf) return 0;
        found = cf;
    }
    return found;
}
// nvn_drv_nvrm_recode: an NvColorFormat in the 6.4–10.9 encoding (the host's table) → the same format in the encoding whose RGBA8 is drv_rgba8 (nvn_drv_nvrm_rgba8_scan). The colour
//   space (bits 32 and up) moves by drv_rgba8's minus RGBA8's 1, the field at bits 16–31 moves up by the bits that take RGBA8's 0x0053 to drv_rgba8's (0 or 1 in every driver seen),
//   bits 0–15 stay. drv_rgba8 0 or not of that shape, or cf 0 (no NvColorFormat): cf unchanged. Every format the host lists moves this way in the 11.4–14.3 and 15.3–20.5 drivers
//   (R8 0xE_0920_0408 → 0xF_0920_0408 → 0xF_1240_0408, BGRA8 0x1_00D1_2120 → 0x2_00D1_2120 → 0x2_01A2_2120; DRAGON QUEST X 13.3 and an SDK 16.2 driver disassembled).
static inline uint64_t nvn_drv_nvrm_recode(uint64_t cf, uint64_t drv_rgba8) {
    if (!cf || (drv_rgba8 & 0xffff) != 0x2120 || (drv_rgba8 >> 32) < 1) return cf;
    int sh = -1; for (int k = 0; k < 4; k++) if (((drv_rgba8 >> 16) & 0xffff) == (uint64_t)0x53 << k) sh = k;
    if (sh < 0) return cf;
    return ((cf >> 32) + (drv_rgba8 >> 32) - 1) << 32 | (((cf >> 16) & 0xffff) << (16 + sh) & 0xffff0000ull) | (cf & 0xffff);
}
