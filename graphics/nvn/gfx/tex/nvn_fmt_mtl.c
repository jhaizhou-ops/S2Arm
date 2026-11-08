// NVNformat (nvn.h 0x01–0x9C) → Metal. The table is written entry by entry in NVN enum order; unlisted formats (including 0 and out of range) return 0.
// Component remapping: "no alpha" formats such as RGBX / RGB_DXT1 read a as 1; RGB-family 16-bit packed formats swap r/b; all others are identity.
// BC1–7 on iOS require GPU BC support (MTLDevice.supportsBCTextureCompression, iOS 16.4+; A19 supports it; device capability is not checked in this table).
#include "nvn_fmt_mtl.h"
#include "../nvn/nvn_fmt_info.h"
#include "../nvn/nvn_fmt_expand.h"
#include <string.h>

enum {   // MTLPixelFormat
    R8Unorm = 10, R8Snorm = 12, R8Uint = 13, R8Sint = 14, R16Unorm = 20, R16Snorm = 22, R16Uint = 23, R16Sint = 24, R16Float = 25,
    RG8Unorm = 30, RG8Snorm = 32, RG8Uint = 33, RG8Sint = 34, B5G6R5Unorm = 40, A1BGR5Unorm = 41, ABGR4Unorm = 42, BGR5A1Unorm = 43,
    R32Uint = 53, R32Sint = 54, R32Float = 55, RG16Unorm = 60, RG16Snorm = 62, RG16Uint = 63, RG16Sint = 64, RG16Float = 65,
    RGBA8Unorm = 70, RGBA8Unorm_sRGB = 71, RGBA8Snorm = 72, RGBA8Uint = 73, RGBA8Sint = 74, BGRA8Unorm = 80, BGRA8Unorm_sRGB = 81,
    RGB10A2Unorm = 90, RGB10A2Uint = 91, RG11B10Float = 92, RGB9E5Float = 93, RG32Uint = 103, RG32Sint = 104, RG32Float = 105,
    RGBA16Unorm = 110, RGBA16Snorm = 112, RGBA16Uint = 113, RGBA16Sint = 114, RGBA16Float = 115, RGBA32Uint = 123, RGBA32Sint = 124,
    RGBA32Float = 125, BC1 = 130, BC1_sRGB = 131, BC2 = 132, BC2_sRGB = 133, BC3 = 134, BC3_sRGB = 135, BC4_U = 140, BC4_S = 141,
    BC5_U = 142, BC5_S = 143, BC6H_S = 150, BC6H_U = 151, BC7 = 152, BC7_sRGB = 153,
    ASTC_SRGB0 = 186, ASTC_LDR0 = 204,   // starting at 4x4; 7x? does not exist, so one number is skipped from 8x5 on (see astc_off)
    Depth16Unorm = 250, Depth32Float = 252, Stencil8 = 253, Depth32Float_Stencil8 = 260,
};

typedef struct { uint16_t mtl; uint8_t kind, noalpha, rb, rev; } ent;   // kind: 1 exact, 2 substitute, 3 expanded on upload (nvn_fmt_expand); noalpha: a reads as 1; rb: swap r/b; rev: all four reversed (r←a, g←b, b←g, a←r)
#define E(m) {m, 1, 0, 0, 0}
#define X(m) {m, 1, 1, 0, 0}     // exact, no alpha
#define S(m) {m, 2, 0, 0, 0}     // substitute
#define N {0, 0, 0, 0, 0}        // no counterpart
#define XP(m) {m, 3, 0, 0, 0}    // expanded on upload into m (nvn_fmt_expand)
#define EV(m) {m, 1, 0, 0, 1} // exact data, components read reversed (the Metal format packs them the other way round)
#define ER(m) {m, 1, 0, 1, 0}   // exact data, r/b swapped by the swizzle
#define XR(m) {m, 1, 1, 1, 0}   // the same, no alpha

static const ent T[0x9D] = {
    [0x01] = E(R8Unorm), E(R8Snorm), E(R8Uint), E(R8Sint),
    [0x05] = E(R16Float), E(R16Unorm), E(R16Snorm), E(R16Uint), E(R16Sint),
    [0x0A] = E(R32Float), E(R32Uint), E(R32Sint),
    [0x0D] = E(RG8Unorm), E(RG8Snorm), E(RG8Uint), E(RG8Sint),
    [0x11] = E(RG16Float), E(RG16Unorm), E(RG16Snorm), E(RG16Uint), E(RG16Sint),
    [0x16] = E(RG32Float), E(RG32Uint), E(RG32Sint),
    // 0x19–0x24 RGB8 / RGB16 / RGB32 three-component: Metal has no 3-component pixel formats. Expanded per pixel (texture upload and buffer-texture binding alike,
    //   nvn_fmt_expand) into the 4-component format of the same kind, a = 1 (the kind's 1: unorm all ones, snorm the largest, integer 1, float 1.0)
    [0x19] = XP(RGBA8Unorm), XP(RGBA8Snorm), XP(RGBA8Uint), XP(RGBA8Sint),
    [0x1D] = XP(RGBA16Float), XP(RGBA16Unorm), XP(RGBA16Snorm), XP(RGBA16Uint), XP(RGBA16Sint),
    [0x22] = XP(RGBA32Float), XP(RGBA32Uint), XP(RGBA32Sint),
    [0x25] = E(RGBA8Unorm), E(RGBA8Snorm), E(RGBA8Uint), E(RGBA8Sint),
    [0x29] = E(RGBA16Float), E(RGBA16Unorm), E(RGBA16Snorm), E(RGBA16Uint), E(RGBA16Sint),
    [0x2E] = E(RGBA32Float), E(RGBA32Uint), E(RGBA32Sint),
    [0x31] = E(Stencil8), E(Depth16Unorm),
    // DEPTH24: Apple GPUs have no Depth24 (Depth24Unorm_Stencil8 is unavailable on iOS) → Depth32Float: as a render target this is a precision upgrade with equivalent behavior;
    // marked substitute only because uploading existing 24-bit depth data requires conversion to float (render targets are not affected)
    [0x33] = S(Depth32Float), E(Depth32Float),
    // DEPTH24_STENCIL8 → Depth32Float_Stencil8 (as above: precision upgrade as a render target, equivalent behavior; marked substitute because uploaded data needs conversion); DEPTH32F_STENCIL8 is exact
    [0x35] = S(Depth32Float_Stencil8), E(Depth32Float_Stencil8),
    [0x37] = X(RGBA8Unorm_sRGB), E(RGBA8Unorm_sRGB),
    // 16-bit packed formats (verified 11-03): NVN names them from the lowest bits up — RGBA4 = r in bits 0–3 … a in 12–15 (Taiko no Tatsujin: Rhythmic Adventure Pack's avatar
    //   sprites read from the device decode right only that way; Ryujinx: Maxwell A4B4G4R4 → VK_FORMAT_A4B4G4R4_UNORM_PACK16, and its A1B5G5R5 / B5G6R5 carry r in the low bits too).
    //   Metal's packing measured on an M5 Max (shader read of single-bit texels): ABGR4Unorm r 15–12 g 11–8 b 7–4 a 3–0; B5G6R5Unorm r 15–11 g 10–5 b 4–0;
    //   A1BGR5Unorm r 15–11 g 10–6 b 5–1 a 0; BGR5A1Unorm a 15 r 14–10 g 9–5 b 4–0. So the data goes up as it is and the swizzle puts the fields back:
    //   RGBA4 → ABGR4 reversed (EV: read as is r↔a, g↔b — the avatar's pink rabbit came out cyan on a yellow block); RGB565 / RGB5A1 / RGB5 → the same-sized BGR Metal format with r/b swapped;
    //   BGR565 / BGR5A1 / BGR5 / A1BGR5 → the same-named Metal format as is. As a render target the swizzle does not apply (writes land in Metal's order: tex_guest_order in nvn_mtl.m).
    //   t_fmt_mtl checks every one of them on the GPU against fields worked out by hand from the rule above
    [0x39] = EV(ABGR4Unorm), XR(BGR5A1Unorm), ER(BGR5A1Unorm), ER(B5G6R5Unorm),
    [0x3D] = E(RGB10A2Unorm), E(RGB10A2Uint), E(RG11B10Float), E(RGB9E5Float),
    // DXT / RGTC / BPTC = BC1–7; RGB_DXT1 has no alpha
    [0x41] = X(BC1), E(BC1), E(BC2), E(BC3), X(BC1_sRGB), E(BC1_sRGB), E(BC2_sRGB), E(BC3_sRGB),
    [0x49] = E(BC4_U), E(BC4_S), E(BC5_U), E(BC5_S), E(BC7), E(BC7_sRGB), E(BC6H_S), E(BC6H_U),
    // *_UI2F / *_I2F: integer storage that the texture fetch reads as float without normalizing (200 → 200.0), the same rule as the vertex attributes (nvn_mtl.m vconv_i2f).
    //   The translated shaders sample every texture as float (the answer table holds only dimensions), so an integer Metal texture there read undefined values (缺口族 30):
    //   expanded on upload into float, 8-bit values into half, 16 / 32-bit into float (exact up to 2^24), three components into four (a = 1.0)
    [0x51] = XP(R16Float), XP(R16Float), XP(R32Float), XP(R32Float), XP(R32Float), XP(R32Float),
    [0x57] = XP(RG16Float), XP(RG16Float), XP(RG32Float), XP(RG32Float), XP(RG32Float), XP(RG32Float),
    [0x5D] = XP(RGBA16Float), XP(RGBA16Float), XP(RGBA32Float), XP(RGBA32Float), XP(RGBA32Float), XP(RGBA32Float),
    [0x63] = XP(RGBA16Float), XP(RGBA16Float), XP(RGBA32Float), XP(RGBA32Float), XP(RGBA32Float), XP(RGBA32Float),
    // RGB10A2 signed: Metal only has Unorm / Uint. SN → RGBA16Snorm (10-bit x / 511, 2-bit a / 1), I → RGBA16Sint, UI2F / I2F → RGBA16Float (10-bit integers are exact in half)
    [0x69] = XP(RGBA16Snorm), XP(RGBA16Sint), XP(RGBA16Float), XP(RGBA16Float),
    [0x6D] = X(RGBA8Unorm), X(RGBA8Snorm), X(RGBA8Uint), X(RGBA8Sint),
    [0x71] = X(RGBA16Float), X(RGBA16Unorm), X(RGBA16Snorm), X(RGBA16Uint), X(RGBA16Sint),
    [0x76] = X(RGBA32Float), X(RGBA32Uint), X(RGBA32Sint),
    // 0x79–0x94 ASTC is computed by astc_off (two groups, LDR / sRGB, 14 each)
    [0x95] = E(B5G6R5Unorm), X(BGR5A1Unorm), E(BGR5A1Unorm), E(A1BGR5Unorm),
    [0x99] = X(BGRA8Unorm), E(BGRA8Unorm), X(BGRA8Unorm_sRGB), E(BGRA8Unorm_sRGB),
};

// NVN ASTC order: 4x4 5x4 5x5 6x5 6x6 8x5 8x6 8x8 10x5 10x6 10x8 10x10 12x10 12x12; Metal skips one number between 6x6 and 8x5
static const uint8_t astc_off[14] = {0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14};

static int mtl_bytes(uint32_t pf) {   // bytes per pixel of the formats the expansions write
    switch (pf) { case R16Float: return 2; case R32Float: case RG16Float: case RGBA8Unorm: case RGBA8Snorm: case RGBA8Uint: case RGBA8Sint: return 4;
                  case RG32Float: case RGBA16Float: case RGBA16Unorm: case RGBA16Snorm: case RGBA16Uint: case RGBA16Sint: return 8;
                  case RGBA32Float: case RGBA32Uint: case RGBA32Sint: return 16; default: return 0; }
}
int nvn_fmt_expanded(uint32_t f, uint32_t *mtl, int *bpp) {
    nvn_fmt_info info;
    if (!nvn_fmt_info_of(f, &info) || f == 0 || f >= sizeof T / sizeof *T || T[f].kind != 3) return 0;
    if (mtl) *mtl = T[f].mtl;
    if (bpp) *bpp = mtl_bytes(T[f].mtl);
    return 1;
}
int nvn_fmt_expand(uint32_t f, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch) {
    return nvn_fmt_expand_upload(f, src, pitch, w, h, dst, dpitch);
}

int nvn_fmt_to_mtl(int f, uint32_t *mtl, uint8_t swz[4]) {
    nvn_fmt_info info;
    int known = nvn_fmt_info_of((uint32_t)f, &info);   // 只映射中立表里有的格式
    ent e = {0, 0, 0, 0, 0};
    if (known && f >= 0x79 && f <= 0x94) { int k = (f - 0x79) % 14; e = (ent){(uint16_t)((f < 0x87 ? ASTC_LDR0 : ASTC_SRGB0) + astc_off[k]), 1, 0, 0, 0}; }
    else if (known && f > 0 && f < (int)(sizeof T / sizeof *T)) e = T[f];
    if (mtl) *mtl = e.kind ? e.mtl : 0;
    if (swz && e.rev) { swz[0] = NVN_SWZ_A; swz[1] = NVN_SWZ_B; swz[2] = NVN_SWZ_G; swz[3] = NVN_SWZ_R; }
    else if (swz) { swz[0] = e.rb ? NVN_SWZ_B : NVN_SWZ_R; swz[1] = NVN_SWZ_G; swz[2] = e.rb ? NVN_SWZ_R : NVN_SWZ_B; swz[3] = e.noalpha ? NVN_SWZ_ONE : NVN_SWZ_A; }
    return e.kind;
}
