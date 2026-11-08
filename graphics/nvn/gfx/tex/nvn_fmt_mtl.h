// NVNformat → Metal pixel format + component remapping. Pure C, no dependency on Metal headers (values taken from the SDK's MTLPixelFormat.h / MTLTexture.h, iOS 26.5 SDK).
#pragma once
#include <stdint.h>

// MTLTextureSwizzle values
enum { NVN_SWZ_ZERO = 0, NVN_SWZ_ONE = 1, NVN_SWZ_R = 2, NVN_SWZ_G = 3, NVN_SWZ_B = 4, NVN_SWZ_A = 5 };

// Returns: 1 = exact match (data uploaded as is); 3 = expanded on upload (nvn_fmt_expanded / nvn_fmt_expand: three components into four, *_UI2F / *_I2F into float, RGB10A2 signed into 16 bits);
//          2 = substitute (precision / bit order / read mode differs: upload needs conversion or the shader must read differently; per-format handling is in the table comments in nvn_fmt_mtl.c);
//          0 = no Metal counterpart (*mtl is set to 0).
// swz gives, for each of the four output components r/g/b/a, which source component to take (MTLTextureSwizzleChannels order); may be NULL.
int nvn_fmt_to_mtl(int nvn_format, uint32_t *mtl_pixel_format, uint8_t swz[4]);
#include <stddef.h>
// A format the host expands on upload (kind 3): → 1 with *mtl = the Metal format it is expanded into, *bpp = its bytes per pixel; else 0
int nvn_fmt_expanded(uint32_t nvn_format, uint32_t *mtl_pixel_format, int *bpp);
// Expands a w×h region: src rows of pitch bytes in the NVN format, dst rows of dpitch bytes in the expanded format. 0 on success, -1 if the format is not one of them
int nvn_fmt_expand(uint32_t nvn_format, const uint8_t *src, size_t pitch, uint32_t w, uint32_t h, uint8_t *dst, size_t dpitch);
