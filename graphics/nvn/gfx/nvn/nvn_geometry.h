// Primitive assembly for geometry compute. Values are capture-record indices;
// restart separates runs before strips/fans are assembled. No game-specific state.
#pragma once
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stddef.h>

static int nvn_geo_topology(int prim) {
    switch (prim) {
        case 0: return 0;
        case 1: case 2: case 3: return 1;
        case 10: case 11: return 2;
        case 4: case 5: case 6: case 7: return 3;
        case 12: return 4;
        default: return -1;
    }
}
static int nvn_geo_width(int topology) { static const int width[] = {1, 2, 4, 3, 6}; return topology >= 0 && topology < 5 ? width[topology] : 0; }

// Returns words required/written. SIZE_MAX means unsupported topology or overflow.
// dst == NULL counts only. A short destination is never partially written.
static size_t nvn_geo_assemble(int prim, const uint32_t *src, size_t count, int restart, uint32_t restart_index, uint32_t *dst, size_t capacity) {
    int width = nvn_geo_width(nvn_geo_topology(prim));
    if (!width) return SIZE_MAX;
    // List primitives without restart (points, lines, triangles, lines / triangles with adjacency): primitive i is src[per*i .. per*i+per), per = width, so the assembled
    //   words are the first count / per * per indices as they are. One copy instead of the per-element switch below (11-06 Switch2 线 71: Donkey Kong Bananza replay,
    //   nvn_geo_assemble 9.8% of the submit thread's samples; geo_draw calls it twice per geometry draw, once to count)
    if (!restart && (prim == 0 || prim == 1 || prim == 4 || prim == 10 || prim == 12)) {
        size_t words = count / (size_t)width * (size_t)width;
        if (dst) { if (words > capacity) return SIZE_MAX; memcpy(dst, src, words * sizeof *dst); }
        return words;
    }
    if (dst) {
        size_t needed = nvn_geo_assemble(prim, src, count, restart, restart_index, NULL, 0);
        if (needed == SIZE_MAX || needed > capacity) return SIZE_MAX;
    }
    size_t words = 0;
    for (size_t begin = 0; begin < count;) {
        size_t end = begin;
        while (end < count && !(restart && src[end] == restart_index)) end++;
        size_t n = end - begin, np = 0;
        switch (prim) {
            case 0: np = n; break;
            case 1: np = n / 2; break;
            case 2: np = n > 1 ? n : 0; break;
            case 3: np = n > 1 ? n - 1 : 0; break;
            case 4: np = n / 3; break;
            case 5: case 6: np = n > 2 ? n - 2 : 0; break;
            case 7: np = n / 4 * 2; break;
            case 10: np = n / 4; break;
            case 11: np = n > 3 ? n - 3 : 0; break;
            case 12: np = n / 6; break;
        }
        if (np > (SIZE_MAX - words) / (size_t)width) return SIZE_MAX;
        if (dst && words + np * width > capacity) return SIZE_MAX;
        for (size_t i = 0; dst && i < np; i++) {
            size_t k[6] = {0};
            switch (prim) {
                case 0: k[0] = i; break;
                case 1: k[0] = 2*i; k[1] = 2*i+1; break;
                case 2: k[0] = i; k[1] = (i+1)%n; break;
                case 3: k[0] = i; k[1] = i+1; break;
                case 4: for (int c=0;c<3;c++) k[c]=3*i+c; break;
                case 5: k[0]=i+(i&1); k[1]=i+1-(i&1); k[2]=i+2; break;
                case 6: k[0]=0; k[1]=i+1; k[2]=i+2; break;
                case 7: k[0]=4*(i/2); k[1]=k[0]+1+(i&1); k[2]=k[1]+1; break;
                case 10: for (int c=0;c<4;c++) k[c]=4*i+c; break;
                case 11: for (int c=0;c<4;c++) k[c]=i+c; break;
                case 12: for (int c=0;c<6;c++) k[c]=6*i+c; break;
            }
            for (int c=0;c<width;c++) dst[words+i*width+c]=src[begin+k[c]];
        }
        words += np * width;
        begin = end < count ? end + 1 : end;
    }
    return words;
}

// 升序去重（S2Arm 11-06 能耗线：金刚提交线程 Time Profiler，geo_draw 给抓顶点的下标排序去重，qsort 占翻译时间 28.6%）：
//   v[0..n) 都在 [lo, hi] 里。顶点号范围不大时在位图上打标、按位升序收（一遍打标 + 一遍扫字），结果与「排序后去重」逐项相同：
//   升序、无重复。范围相对个数太宽（扫的字数 > 4n + 1024）或位图超过 8 MiB 时退回排序（qsort 原地，再去重）。
//   dst 可以就是 v（位图那条先读完再写，排序那条去重时 k ≤ i）；bm / bm_words：调用方留着复用的位图
enum { NVN_GEO_UQ_MAX_WORDS = 1u << 20 };
static int nvn_geo_cmp_u32(const void *a, const void *b) { uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b; return (x > y) - (x < y); }
static int nvn_geo_unique_bitmap_ok(size_t n, uint32_t lo, uint32_t hi) {
    uint64_t w = ((uint64_t)hi - lo) / 64 + 1;
    return lo <= hi && w <= NVN_GEO_UQ_MAX_WORDS && w <= 4 * (uint64_t)n + 1024;
}
static size_t nvn_geo_unique_sorted(uint32_t *v, size_t n, uint32_t lo, uint32_t hi, uint32_t *dst, uint64_t **bm, size_t *bm_words) {
    if (!n) return 0;
    if (nvn_geo_unique_bitmap_ok(n, lo, hi)) {
        size_t w = (size_t)(((uint64_t)hi - lo) / 64 + 1);
        if (*bm_words < w) { uint64_t *nb = (uint64_t *)realloc(*bm, w * sizeof *nb); if (nb) { *bm = nb; *bm_words = w; } }
        if (*bm_words >= w) {
            memset(*bm, 0, w * sizeof **bm);
            for (size_t i = 0; i < n; i++) { uint32_t x = v[i] - lo; (*bm)[x >> 6] |= 1ull << (x & 63); }
            size_t k = 0;
            for (size_t i = 0; i < w; i++) for (uint64_t b = (*bm)[i]; b; b &= b - 1) dst[k++] = lo + (uint32_t)(i * 64 + (size_t)__builtin_ctzll(b));
            return k;
        }
    }
    qsort(v, n, sizeof *v, nvn_geo_cmp_u32);
    size_t k = 0;
    for (size_t i = 0; i < n; i++) if (!i || v[i] != v[i - 1]) dst[k++] = v[i];
    return k;
}

// One ordered compaction per draw. Output is a point/line/triangle list, so it
// does not depend on Metal primitive-restart behaviour. Preserve triangle-strip
// winding and the last vertex. Unwritten GS index slots are UINT_MAX.
// One threadgroup walks the GS invocations a chunk of threads at a time: each thread counts its invocation's primitives, a threadgroup prefix sum places them after
//   everything before (the same order and the same words as one thread going through the invocations in turn), then each thread writes its own. A primitive is written
//   only when it fits whole in capacity (k words each: 1 point / 2 line / 3 triangle), args[0] = the words written.
// 11-02 Nintendo Switch Sports: this was one thread looping over every invocation (760 primitives × the index stride, about 3.9 ms a draw, 8 geometry draws a frame,
//   10 of the menu's 12 ms of GPU time, as long on an M5 Max as on an A19 Pro: clock-bound). About 80 s into the menu iOS holds the GPU at its minimum performance state
//   (Metal System Trace, thermal nominal; it stays there with this kernel too), the single thread 5× slower with it: 12 → 57 ms frames, 330 ms on the plaza
static const char k_nvn_geo_pack_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct geo_pack { device const uint *src; device uint *dst; device uint *args; uint groups, stride, topology, capacity; };\n"
"static uint geo_pack_group(constant geo_pack& j, uint g, uint at, uint lim, bool wr) {\n"
" uint a=0,b=0,n=0,c=0;\n"
" for(uint i=0;i<j.stride;i++) { uint v=j.src[g*j.stride+i];\n"
"  if(v==0xffffffffu) {n=0;continue;}\n"
"  if(j.topology==1) {if(wr && at+c<lim) j.dst[at+c]=v; c++;}\n"
"  else if(j.topology==6) {if(n) {if(wr && at+c<lim) {j.dst[2*(at+c)]=b;j.dst[2*(at+c)+1]=v;} c++;}}\n"
"  else if(n>=2) {if(wr && at+c<lim) {uint o=3*(at+c);j.dst[o]=(n&1)?b:a;j.dst[o+1]=(n&1)?a:b;j.dst[o+2]=v;} c++;}\n"
"  a=b;b=v;n++;\n"
" }\n"
" return c;\n"
"}\n"
"kernel void geo_pack_indices(constant geo_pack& j [[buffer(0)]], uint t [[thread_position_in_threadgroup]], uint tn [[threads_per_threadgroup]],\n"
"                             uint sl [[thread_index_in_simdgroup]], uint si [[simdgroup_index_in_threadgroup]], uint sn [[simdgroups_per_threadgroup]]) {\n"
" threadgroup uint part[32]; threadgroup uint tot;\n"
" uint k=j.topology==1?1u:j.topology==6?2u:3u, lim=j.capacity/k, base=0;\n"
" for(uint g0=0;g0<j.groups;g0+=tn) { uint g=g0+t, c=g<j.groups?geo_pack_group(j,g,0,0,false):0;\n"
"  uint x=simd_prefix_exclusive_sum(c), s=simd_sum(c);\n"
"  if(sl==0) part[si]=s;\n"
"  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"  if(si==0) { uint p=sl<sn?part[sl]:0, px=simd_prefix_exclusive_sum(p), ps=simd_sum(p); if(sl<sn) part[sl]=px; if(sl==0) tot=ps; }\n"
"  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
"  if(c) geo_pack_group(j,g,base+part[si]+x,lim,true);\n"
"  base+=tot;\n"
"  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
" }\n"
" if(t==0) {j.args[0]=min(base,lim)*k;j.args[1]=1;j.args[2]=0;j.args[3]=0;j.args[4]=0;}\n"
"}\n";

// S2Arm geometry transform feedback (10-26, Xenoblade 3): the GPU's feedback stage captures the last vertex stage, here the geometry shader. Its emitted vertices are the
// output records (one record of rec_words per vertex, the translator's offsets), and the compacted list (geo_pack_indices) is what the hardware assembles: list i is the i-th
// captured vertex. Buffer b gets, for each vertex, its entries' components packed in order (stride bytes per vertex), from the buffer's current offset, as many whole primitives
// as fit (NVN overflow: capture stops). The offset is the host's (start, known on the CPU) until a geometry capture, then the GPU counter cnt[b] (bytes, the CPU cannot know how many
// vertices the shader emitted); geo_tf_count moves the counter after geo_tf_write, in a later encoder. tf_draw_args turns a counter into DrawArraysIndirect arguments.
static const char k_nvn_geo_tf_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct geo_tf { device const uint *rec; device const uint *idx; device const uint *args; device uint *cnt; device uint *dst[4];\n"
" uint size[4], stride[4], start[4], ne[4]; uint use_cnt, rec_words, per_prim, pad; uint off[4][32], comp[4][32]; };\n"
"static uint tf_room(constant geo_tf& j, uint b, uint s0) { uint n=j.args[0], room=j.size[b]>s0?(j.size[b]-s0)/j.stride[b]:0, m=min(n,room); return m-m%j.per_prim; }\n"
"kernel void geo_tf_write(constant geo_tf& j [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
" for(uint b=0;b<4;b++) { if(!j.stride[b]) continue; uint s0=j.use_cnt?j.cnt[b]:j.start[b]; if(i>=tf_room(j,b,s0)) continue;\n"
"  device uint *d=j.dst[b]+(s0+i*j.stride[b])/4; device const uint *r=j.rec+j.idx[i]*j.rec_words; uint w=0;\n"
"  for(uint e=0;e<j.ne[b];e++) for(uint c=0;c<j.comp[b][e];c++) d[w++]=r[j.off[b][e]+c];\n"
" }\n"
"}\n"
"kernel void geo_tf_count(constant geo_tf& j [[buffer(0)]]) {\n"
" for(uint b=0;b<4;b++) { if(!j.stride[b]) continue; uint s0=j.use_cnt?j.cnt[b]:j.start[b]; j.cnt[b]=s0+tf_room(j,b,s0)*j.stride[b]; }\n"
"}\n"
"struct tf_args { device const uint *cnt; device uint *args; uint b, stride; };\n"
"kernel void tf_draw_args(constant tf_args& j [[buffer(0)]]) { j.args[0]=j.stride?j.cnt[j.b]/j.stride:0; j.args[1]=1; j.args[2]=0; j.args[3]=0; }\n"
"kernel void tf_snap(constant tf_args& j [[buffer(0)]]) { for(uint b=0;b<4;b++) j.args[b]=j.cnt[b]; }\n";
typedef struct { uint64_t rec, idx, args, cnt, dst[4]; uint32_t size[4], stride[4], start[4], ne[4]; uint32_t use_cnt, rec_words, per_prim, pad; uint32_t off[4][32], comp[4][32]; } nvn_geo_tf;
typedef struct { uint64_t cnt, args; uint32_t b, stride; } nvn_tf_args;
// S2Arm vertex transform feedback of indexed draws (nvn_mtl.m tf_draw): the vertex function captures the index range [lo, hi] into scratch (slot = vertex id − lo, per instance),
// and this kernel copies the records into the feedback buffer in draw order: dst record i = src record map[i] (words per record = stride / 4)
static const char k_tf_gather_msl[] =
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct tf_gather { device const uint *src; device uint *dst; device const uint *map; uint words, n; };\n"
"kernel void tf_gather(constant tf_gather& j [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
" if (i >= j.n) return; uint s = j.map[i];\n"
" for (uint w = 0; w < j.words; w++) j.dst[i * j.words + w] = j.src[s * j.words + w];\n"
"}\n";
typedef struct { uint64_t src, dst, map; uint32_t words, n; } nvn_tf_gather;
