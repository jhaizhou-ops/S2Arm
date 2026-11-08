// CRI CRILAYLA 解压（CPK 文件压缩；P5R 等 CRI 中间件游戏）：输入以 "CRILAYLA" 开头：+8 原长、+12 未压缩头偏移，数据按位从尾往前读，
// 末尾 0x100 字节是原样的文件头。返回写出的字节数（= 0x100 + 原长），出错返回 -1。算法同公开实现（CriPakTools DecompressCRILAYLA）
#include <stdint.h>
#include <string.h>
typedef struct { const uint8_t *in; long off; uint8_t pool; int left; } bits_t;
static int nb(bits_t *b, int n) {
    unsigned out = 0; int got = 0;
    while (got < n) {
        if (b->left == 0) { if (b->off < 0) return -1; b->pool = b->in[b->off--]; b->left = 8; }
        int k = b->left < n - got ? b->left : n - got;
        out = (out << k) | ((b->pool >> (b->left - k)) & ((1u << k) - 1));
        b->left -= k; got += k;
    }
    return (int)out;
}
// Windows 上 clang -shared 不导出没标记的函数（ctypes 报「function 'crilayla_dec' not found」，11-05 天眼 P5R），要显式导出；类 Unix 缺省全导出
#ifdef _WIN32
__declspec(dllexport)
#endif
long crilayla_dec(const uint8_t *in, long n, uint8_t *out, long cap) {
    if (n < 0x110 || memcmp(in, "CRILAYLA", 8)) return -1;
    uint32_t us, ho; memcpy(&us, in + 8, 4); memcpy(&ho, in + 12, 4);
    if ((long)us + 0x100 > cap || (long)ho + 0x10 + 0x100 > n) return -1;
    memcpy(out, in + ho + 0x10, 0x100);
    static const int vle[4] = {2, 3, 5, 8};
    bits_t b = { in, n - 0x100 - 1, 0, 0 };
    long oend = 0x100 + (long)us - 1, done = 0;
    while (done < (long)us) {
        int f = nb(&b, 1); if (f < 0) return -1;
        if (f) {
            int r = nb(&b, 13); if (r < 0) return -1;
            long src = oend - done + r + 3; long len = 3; int lv;
            for (lv = 0; lv < 4; lv++) { int t = nb(&b, vle[lv]); if (t < 0) return -1; len += t; if (t != (1 << vle[lv]) - 1) break; }
            if (lv == 4) { int t; do { t = nb(&b, 8); if (t < 0) return -1; len += t; } while (t == 255); }
            for (long i = 0; i < len && done < (long)us; i++) { if (src > oend || src < 0) return -1; out[oend - done] = out[src--]; done++; }
        } else { int v = nb(&b, 8); if (v < 0) return -1; out[oend - done] = (uint8_t)v; done++; }
    }
    return 0x100 + (long)us;
}
