// macOS PNG codec + pixel measurements. No game/runtime hooks, no external packages.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_BYTES (128u * 1024u * 1024u)
#define MAX_PIXELS 16777216u
typedef struct { size_t w, h; unsigned char *rgb; } Raster;
static void fail(const char *message) { fprintf(stderr, "%s\n", message); exit(2); }
static void *allocate(size_t n) { void *p = calloc(1, n); if (!p) fail("allocation failed"); return p; }
static unsigned char *read_bytes(size_t n) {
    if (!n || n > MAX_BYTES) fail("input byte limit");
    unsigned char *p = allocate(n);
    if (fread(p, 1, n, stdin) != n) fail("truncated codec input");
    return p;
}
static uint32_t read_u32(void) {
    unsigned char b[4];
    if (fread(b, 1, 4, stdin) != 4) fail("missing input length");
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}
static size_t property(CFDictionaryRef props, CFStringRef key, size_t fallback) {
    CFTypeRef value = CFDictionaryGetValue(props, key);
    long long n = 0;
    if (!value) return fallback;
    if (CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue(value, kCFNumberLongLongType, &n) || n < 0) fail("invalid PNG property");
    return (size_t)n;
}
static Raster decode(unsigned char *bytes, size_t n) {
    static const unsigned char magic[8] = {137,80,78,71,13,10,26,10};
    if (n < 29 || memcmp(bytes, magic, 8) || bytes[24] != 8) fail("requires 8-bit PNG");
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, bytes, (CFIndex)n);
    CGImageSourceRef source = CGImageSourceCreateWithData(data, NULL);
    if (!source || CGImageSourceGetCount(source) != 1) fail("PNG source invalid");
    CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if (!props) fail("PNG properties invalid");
    size_t w = property(props, kCGImagePropertyPixelWidth, 0), h = property(props, kCGImagePropertyPixelHeight, 0);
    if (!w || !h || w > 16384 || h > 16384 || w * h > MAX_PIXELS) fail("PNG dimension limit");
    if (property(props, kCGImagePropertyOrientation, 1) != 1) fail("rotated PNG unsupported");
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    if (!image) fail("PNG decode failed");
    unsigned char *rgba = allocate(w * h * 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba, w, h, 8, w * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) fail("sRGB context failed");
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
    Raster result = {w, h, allocate(w * h * 3)};
    for (size_t i = 0; i < w * h; ++i) {
        if (rgba[i * 4 + 3] != 255) fail("transparent PNG unsupported");
        memcpy(result.rgb + i * 3, rgba + i * 4, 3);
    }
    CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image);
    CFRelease(props); CFRelease(source); CFRelease(data); free(rgba);
    return result;
}
static Raster read_raster(void) {
    size_t n = read_u32();
    unsigned char *bytes = read_bytes(n);
    Raster image = decode(bytes, n); free(bytes); return image;
}
static void write_png(Raster r, const char *path) {
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, r.rgb, (CFIndex)(r.w * r.h * 3));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(r.w, r.h, 8, 24, r.w * 3, space, kCGImageAlphaNone,
        provider, NULL, false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
        (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (!image || !dst) fail("cannot create heatmap");
    CGImageDestinationAddImage(dst, image, NULL);
    if (!CGImageDestinationFinalize(dst)) fail("cannot write heatmap");
    CFRelease(dst); CFRelease(url); CGImageRelease(image); CGColorSpaceRelease(space);
    CGDataProviderRelease(provider); CFRelease(data);
}
static void inspect(Raster a) {
    double sums[192] = {0}; size_t counts[64] = {0};
    for (size_t y = 0; y < a.h; ++y) for (size_t x = 0; x < a.w; ++x) {
        size_t cell = (y * 8 / a.h) * 8 + x * 8 / a.w;
        ++counts[cell];
        for (size_t c = 0; c < 3; ++c) sums[cell * 3 + c] += a.rgb[(y * a.w + x) * 3 + c];
    }
    printf("{\"width\":%zu,\"height\":%zu,\"feature\":[", a.w, a.h);
    for (size_t i = 0; i < 192; ++i) printf("%s%.17g", i ? "," : "",
        counts[i / 3] ? sums[i] / ((double)counts[i / 3] * 255) : 0);
    // Testable canonical byte order: top left first, then row major RGB.
    printf("],\"topLeftRGB\":[%u,%u,%u]}\n", a.rgb[0], a.rgb[1], a.rgb[2]);
}
static void measure(Raster a, Raster b, const char *heat_path, int delta, size_t block, int near_black, const char *mask_path) {
    if (a.w != b.w || a.h != b.h) fail("frame dimensions differ");
    Raster heat = {a.w, a.h, allocate(a.w * a.h * 3)};
    size_t tiles = ((a.w + block - 1) / block) * ((a.h + block - 1) / block), tile = 0;
    unsigned char *mask = allocate(tiles);
    if (mask_path) {
        FILE *f = fopen(mask_path, "rb");
        if (!f || fread(mask, 1, tiles, f) != tiles || fgetc(f) != EOF) fail("invalid mask size");
        fclose(f);
        for (size_t i = 0; i < tiles; ++i) if (mask[i] > 1) fail("invalid mask value");
    }
    size_t changed = 0; int max_delta = 0; double total_error = 0, total_ssim = 0;
    int first = 1;
    printf("{\"width\":%zu,\"height\":%zu,\"blocks\":[", a.w, a.h);
    for (size_t y = 0; y < a.h; y += block) for (size_t x = 0; x < a.w; x += block) {
        size_t bw = fmin(block, a.w - x), bh = fmin(block, a.h - y), changed_block = 0;
        double n = (double)(bw * bh), error = 0, ssim = 0;
        double lum[2] = {0}, lum2[2] = {0}; size_t nonblack[2] = {0}; int block_max = 0;
        double sx[3] = {0}, sy[3] = {0}, sxx[3] = {0}, syy[3] = {0}, sxy[3] = {0};
        for (size_t yy = y; yy < y + bh; ++yy) for (size_t xx = x; xx < x + bw; ++xx) {
            size_t p = (yy * a.w + xx) * 3; int maximum = 0;
            for (size_t c = 0; c < 3; ++c) {
                double av = a.rgb[p + c], bv = b.rgb[p + c];
                sx[c] += av; sy[c] += bv; sxx[c] += av * av; syy[c] += bv * bv; sxy[c] += av * bv;
                int d = abs((int)a.rgb[p + c] - (int)b.rgb[p + c]);
                maximum = maximum > d ? maximum : d; error += d;
            }
            double values[2] = {
                .2126 * a.rgb[p] + .7152 * a.rgb[p + 1] + .0722 * a.rgb[p + 2],
                .2126 * b.rgb[p] + .7152 * b.rgb[p + 1] + .0722 * b.rgb[p + 2]};
            for (size_t k = 0; k < 2; ++k) {
                lum[k] += values[k]; lum2[k] += values[k] * values[k];
                nonblack[k] += values[k] > near_black;
            }
            block_max = block_max > maximum ? block_max : maximum;
            changed_block += maximum > delta;
            max_delta = max_delta > maximum ? max_delta : maximum;
            heat.rgb[p] = mask[tile] ? 0 : (unsigned char)maximum;
            heat.rgb[p + 2] = mask[tile] ? 64 : 0;
        }
        for (size_t c = 0; c < 3; ++c) {
            double mx = sx[c] / n, my = sy[c] / n;
            double vx = fmax(0, sxx[c] / n - mx * mx), vy = fmax(0, syy[c] / n - my * my);
            double cov = sxy[c] / n - mx * my;
            ssim += ((2 * mx * my + 6.5025) * (2 * cov + 58.5225)) /
                    ((mx * mx + my * my + 6.5025) * (vx + vy + 58.5225)) / 3;
        }
        printf("%s{\"x\":%zu,\"y\":%zu,\"width\":%zu,\"height\":%zu,\"changedPixels\":%zu,\"mae\":%.17g,\"ssimRGB\":%.17g,\"maxDelta\":%d,"
               "\"leftLumaVariance\":%.17g,\"rightLumaVariance\":%.17g,\"leftNonBlackFraction\":%.17g,\"rightNonBlackFraction\":%.17g}",
               first ? "" : ",", x, y, bw, bh, changed_block, error / (n * 3), ssim, block_max,
               fmax(0, lum2[0] / n - (lum[0] / n) * (lum[0] / n)),
               fmax(0, lum2[1] / n - (lum[1] / n) * (lum[1] / n)), nonblack[0] / n, nonblack[1] / n);
        ++tile;
        first = 0; changed += changed_block; total_error += error; total_ssim += ssim * n;
    }
    if (strcmp(heat_path, "-")) write_png(heat, heat_path);
    printf("],\"changedPixels\":%zu,\"changedFraction\":%.17g,\"mae\":%.17g,\"maxDelta\":%d,\"ssimRGB\":%.17g}\n",
           changed, (double)changed / (a.w * a.h), total_error / (a.w * a.h * 3), max_delta, total_ssim / (a.w * a.h));
    free(heat.rgb); free(mask);
}
int main(int argc, char **argv) {
    if (argc < 2) fail("codec inspect | compare <heatmap-or-> <delta> <block> [near-black [mask.bin]]");
    if (!strcmp(argv[1], "inspect") && argc == 2) {
        Raster a = read_raster(); if (fgetc(stdin) != EOF) fail("trailing input"); inspect(a); free(a.rgb);
    } else if (!strcmp(argv[1], "compare") && argc >= 5 && argc <= 7) {
        char *end; long delta = strtol(argv[3], &end, 10);
        if (*end || delta < 0 || delta > 254) fail("delta out of range");
        long block = strtol(argv[4], &end, 10);
        if (*end || block < 1 || block > 256) fail("block out of range");
        long near_black = argc >= 6 ? strtol(argv[5], &end, 10) : 16;
        if ((argc >= 6 && *end) || near_black < 0 || near_black > 254) fail("near-black out of range");
        Raster a = read_raster(), b = read_raster(); if (fgetc(stdin) != EOF) fail("trailing input");
        measure(a, b, argv[2], (int)delta, (size_t)block, (int)near_black, argc == 7 ? argv[6] : NULL); free(a.rgb); free(b.rgb);
    } else fail("bad codec command");
    return ferror(stdout) ? 2 : 0;
}
