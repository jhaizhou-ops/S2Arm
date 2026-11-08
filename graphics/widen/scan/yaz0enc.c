// Yaz0 压缩（ui_lyt.py 在包里改了布局、要把 Yaz0 包重压回去时用）：标准 LZ77，窗口 4096、匹配 3..0x111，哈希链（每位置查 4096 个候选）+ 一步惰性匹配。
// 实测塞尔达 Layout/Common.sblarc（解压 33 MB，走惰性）：原包 6345925 字节 → 重压 6338035 字节，3.6 秒；≤8 MB 的包走最优分词（马车8 小包惰性比原包长几字节）。
// 目的：重压后不比原包长 → 原位写回、外层包长度不变（塞尔达 Bootup.pack 按资源尺寸表分配缓冲，变长有加载失败风险）。
// 用法：yaz0enc <解压数据> <输出> <原包前 16 字节的十六进制>；从标准输出打印压缩后长度。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define WIN 0x1000
#define MAXLEN 0x111
#define HBITS 16
#define CHAIN 4096

static const uint8_t *S; static size_t N;
static int32_t head[1 << HBITS], *prev;

static inline uint32_t hash3(size_t i) { return ((S[i] << 16 | S[i + 1] << 8 | S[i + 2]) * 2654435761u) >> (32 - HBITS); }
static size_t ins;   // 已进哈希链的位置上界（单调，每个位置只进一次）
static void upto(size_t i) { for (; ins < i; ins++) if (ins + 2 < N) { uint32_t h = hash3(ins); prev[ins] = head[h]; head[h] = (int32_t)ins; } }
static size_t best(size_t i, size_t *dist) {   // 只在 i 之前的位置里找
    upto(i); if (i + 2 >= N) return 0;
    size_t bl = 0, lim = N - i < MAXLEN ? N - i : MAXLEN; int c = CHAIN;
    for (int32_t j = head[hash3(i)]; j >= 0 && i - (size_t)j <= WIN && c--; j = prev[j]) {
        size_t l = 0; while (l < lim && S[j + l] == S[i + l]) l++;
        if (l > bl) { bl = l; *dist = i - j; if (l == lim) break; }
    }
    return bl >= 3 ? bl : 0;
}

// 最优分词（≤8 MB 用）：先按哈希链求每个位置的最长匹配（距离 d、长度 L，L 以内任意长度同距离都成立），再从尾到头动态规划
// 位开销：字面量 1+8、匹配 ≤0x11 是 1+16、更长 1+24（标志位按每个记号 1 位记），取总开销最小的分法——比贪心 / 惰性更短
static size_t encode_opt(uint8_t *out, size_t o) {
    uint32_t *ml = malloc(4 * N), *md = malloc(4 * N); uint64_t *cost = malloc(8 * (N + 1)); uint32_t *ch = malloc(4 * N);
    for (size_t i = 0; i < N; i++) { size_t d = 0, l = best(i, &d); ml[i] = (uint32_t)l; md[i] = (uint32_t)d; }
    cost[N] = 0;
    for (size_t i = N; i-- > 0;) {
        uint64_t bc = cost[i + 1] + 9; uint32_t bl = 1;
        for (uint32_t l = 3; l <= ml[i]; l++) { uint64_t c = cost[i + l] + (l <= 0x11 ? 17 : 25); if (c < bc) { bc = c; bl = l; } }
        cost[i] = bc; ch[i] = bl;
    }
    size_t i = 0;
    while (i < N) {
        size_t fp = o++; uint8_t flags = 0;
        for (int bit = 0; bit < 8 && i < N; bit++) {
            uint32_t l = ch[i];
            if (l == 1) { flags |= 0x80 >> bit; out[o++] = S[i++]; continue; }
            size_t d = md[i] - 1;
            if (l >= 0x12) { out[o++] = d >> 8; out[o++] = d; out[o++] = (uint8_t)(l - 0x12); }
            else { out[o++] = ((l - 2) << 4) | (d >> 8); out[o++] = d; }
            i += l;
        }
        out[fp] = flags;
    }
    free(ml); free(md); free(cost); free(ch);
    return o;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法：yaz0enc <解压数据> <输出> <原包头 16 字节十六进制>\n"); return 2; }
    FILE *f = fopen(argv[1], "rb"); if (!f) return 1; fseek(f, 0, SEEK_END); N = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *src = malloc(N + 3); if (fread(src, 1, N, f) != N) return 1; fclose(f); S = src;
    prev = malloc(sizeof(int32_t) * (N + 1)); memset(head, 0xff, sizeof head);
    uint8_t *out = malloc(16 + N + N / 8 + 16); size_t o = 16;
    for (int k = 0; k < 16; k++) { unsigned v; sscanf(argv[3] + 2 * k, "%2x", &v); out[k] = (uint8_t)v; }
    out[4] = N >> 24; out[5] = N >> 16; out[6] = N >> 8; out[7] = N;
    if (N <= (8u << 20)) { o = encode_opt(out, o); goto done; }
    size_t i = 0;
    while (i < N) {
        size_t fp = o++; uint8_t flags = 0;
        for (int bit = 0; bit < 8 && i < N; bit++) {
            size_t d1 = 0, l1 = best(i, &d1);
            if (l1) {   // 惰性：下一个位置更长就先出一个字面量
                size_t d2 = 0, l2 = best(i + 1, &d2);
                if (l2 > l1) { flags |= 0x80 >> bit; out[o++] = S[i++]; continue; }
                size_t d = d1 - 1;
                if (l1 >= 0x12) { out[o++] = d >> 8; out[o++] = d; out[o++] = (uint8_t)(l1 - 0x12); }
                else { out[o++] = ((l1 - 2) << 4) | (d >> 8); out[o++] = d; }
                i += l1;
            } else { flags |= 0x80 >> bit; out[o++] = S[i++]; }
        }
        out[fp] = flags;
    }
done:;
    FILE *g = fopen(argv[2], "wb"); fwrite(out, 1, o, g); fclose(g);
    printf("%zu\n", o);
    return 0;
}
