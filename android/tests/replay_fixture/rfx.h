// S2RF：回放核心测试夹具的记录格式与工具库（#784 D2–D7 用；FORMAT.md 是字节级规范）。
//
// 两种文件：
//   输入（kind=RFX_KIND_IN）：REGION / DATA（内存快照，沿用 nvn_frame_rec.inc mem.bin 的记录族）+
//     RES（程序快照 / 着色器产物 / 假窗口）+ CALL（nvn_be_* 上沿调用序列）。
//   期望（kind=RFX_KIND_EXP）：ASSUME（期望所针对的能力档）+ EXP（nvn_gpu_* 下沿调用流，规范化编码）+
//     CHK（检查点：done / retired / presented 回调、栅栏值、缓冲内容）+ END。
//
// 逐字节比对：rfx_cmp 把「记录器（nvn_gpu_* 打点实现）写出的实际流」与期望流逐字节比，0 容差，
// 报第一处差异（记录序号、字节偏移、函数名）。句柄、指针、时刻一律按 FORMAT.md 的规范化规则编码后才有可比性。
//
// 本文件纯 C11、无外部依赖：回放核心、记录器后端、比对器与单测都编译同一份。
#ifndef S2A_RFX_H
#define S2A_RFX_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- 容器 ----------
#define RFX_MAGIC 0x31465852u   // "RFX1"
#define RFX_VERSION 1u

enum { RFX_KIND_IN = 1, RFX_KIND_EXP = 2 };

// 记录号（1–3 与帧录 mem.bin 相同语义，故复用原值；4 起为本夹具新增）
enum {
    RFX_REC_REGION = 1,   // 内存段声明 {u64 addr, u64 len, u64 prot}（同 FR_REC_REGION）
    RFX_REC_DATA = 2,     // 内存内容 {u64 addr, u64 len, u8 bytes[len]}（同 FR_REC_DATA）
    RFX_REC_END = 3,      // 结束（同 FR_REC_END）
    RFX_REC_RES = 4,      // 命名资源 {u32 rkind, u16 name_len, u8 name[..], 负载按 rkind}
    RFX_REC_CALL = 5,     // 上沿调用 {u32 func, u64 ret, 负载按 func}
    RFX_REC_EXP = 6,      // 期望下沿调用 {u32 func, 负载按 func}
    RFX_REC_CHK = 7,      // 检查点 {u32 ckind, 负载按 ckind}
    RFX_REC_ASSUME = 8,   // 能力档声明（期望文件第一条记录）{见 rfx_caps 序列化}
};

// RES rkind
enum {
    RFX_RES_PROG = 1,     // 程序快照（nvn_prog_snap_get 的表项）：{u64 serial, u8 keys[6][8], u8 kok, u8 stage_of[6]}
    RFX_RES_SHADER = 2,   // 着色器产物：{u8 stage, u8 key[8], u8 blob_kind, u16 entry_len, u8 entry[..],
                          //   u32 nent, u32 push_off, u32 push_bytes, u32 support_bytes, u8 id[16], u16 idsrc_len, u8 idsrc[..],
                          //   ent[nent]（每项 16B：set,cls,access,src_kind u8; binding,src_reg,count,aid u16; stages u32）,
                          //   u64 blob_len, u8 blob[..]}
    RFX_RES_SURFACE = 3,  // 假窗口面：{u32 w, u32 h, u32 nvn_format, u32 nimg}
};

// CALL func（上沿 nvn_be_*；id 只增不改，新增从尾部排）
enum {
    RFX_BE_SET_DEPTH_ZERO = 1,      // {u32 on}
    RFX_BE_SET_ORIGIN_LL,           // {u32 on}  nvn_be_set_origin_lower_left
    RFX_BE_POOL_ADD,                // {u64 addr, u64 size}
    RFX_BE_POOL_DEL,                // {u64 addr}
    RFX_BE_ALIAS_DROP_POOL,         // {u64 pool}
    RFX_BE_SUB_INDEX,               // {u32 n, u64 h[n]}
    RFX_BE_SUB_BEGIN,               // {}
    RFX_BE_EXEC,                    // {u64 handle}
    RFX_BE_EXEC_REST,               // {u32 n, u64 h[n]}
    RFX_BE_SUB_COMMIT,              // {}  ret = 栅栏值
    RFX_BE_LAST_FENCE,              // {}  ret = u64
    RFX_BE_WAIT,                    // {u64 fence, u64 timeout_ns}  ret = i32
    RFX_BE_FINISH,                  // {}
    RFX_BE_DRAIN,                   // {}
    RFX_BE_TEX_INIT,                // {u64 tex}
    RFX_BE_TEX_RELEASE,             // {u64 tex}
    RFX_BE_TEX_CPU_WRITTEN,         // {u64 tex}
    RFX_BE_TEX_GPU_OWNED,           // {u64 serial}  ret = i32
    RFX_BE_REG_TEX,                 // {i32 id, u64 tex, u8 has_view, u8 view[16]}  view 按 FORMAT.md §4.2 规则写
    RFX_BE_UNREG_TEX_RANGE,         // {i32 base, i32 n}
    RFX_BE_REG_SAMP,                // {i32 id, u8 samp_par[40]}
    RFX_BE_SET_TEX_POOL_N,          // {i32 n}
    RFX_BE_XV_WINDOW_TEX,           // {u64 serial}
    RFX_BE_PRESENT,                 // {u64 tex, f64 period_s, u8 has_crop, i32 crop[4]}  ret = u64 ticket
    RFX_BE_PRESENT_WAIT,            // {u64 ticket}
    RFX_BE_SET_FRAME,               // {u64 frame}
    RFX_BE_READ_TEXELS,             // {u64 tex, u32 level, u32 layer0, i32 region[6], u64 dst_addr, u64 row, u64 img}
    RFX_BE_PROG_RELEASE,            // {u64 prog}
    RFX_BE_SHADER_PREFETCH,         // {u8 key[8]}
    RFX_BE_FINISH_PUBLISH,          // {}  ret = u64
    RFX_BE_FINISH_WAIT,             // {u64 fence}
    RFX_BE_EVENT_WRITTEN,           // {u64 val_addr}
    RFX_BE_FUNC_N,
};

// EXP func（下沿 nvn_gpu_*；id 与 FORMAT.md §5 表一致）
enum {
    RFX_GPU_OPEN = 1,               // {i32 rc}
    RFX_GPU_CLOSE,                  // {u64 timeout_ns, i32 rc}
    RFX_GPU_BUF_WRAP,               // {u64 host, u64 bytes, i32 rc, u32 hid}
    RFX_GPU_BUF_CREATE,             // {u64 bytes, u8 mem, u64 init_len, u32 init_crc, i32 rc, u32 hid}
    RFX_GPU_BUF_RELEASE,            // {u32 hid, u8 has_retired}
    RFX_GPU_BUF_USE,                // {u32 cmd, u32 buf}
    RFX_GPU_BUF_WRITE,              // {u32 cmd, u32 dst, u64 off, u64 bytes, u32 crc}
    RFX_GPU_ARENA_ALLOC,            // {u32 cmd, u64 bytes, u32 align, i32 rc, u32 hid, u64 off}
    RFX_GPU_TEX_CREATE,             // {nvn_gpu_tex_desc（§4.3 布局）, i32 rc, u32 hid}
    RFX_GPU_TEX_RELEASE,            // {u32 hid}
    RFX_GPU_VIEW_CREATE,            // {u32 tex, u8 has_view, u8 view[16], i32 rc, u32 hid}
    RFX_GPU_VIEW_CREATE_BUF,        // {u32 buf, u64 off, u64 bytes, u32 fmt, i32 rc, u32 hid}
    RFX_GPU_VIEW_RELEASE,           // {u32 hid}
    RFX_GPU_SAMP_CREATE,            // {u8 samp_par[40], i32 rc, u32 hid}
    RFX_GPU_SAMP_RELEASE,           // {u32 hid}
    RFX_GPU_TEX_UPLOAD,             // {u32 cmd, u32 tex, u32 level, u32 layer, i32 region[6], u32 src_buf, u64 src_off, u64 row_bytes, u64 image_bytes, u64 data_len, u32 crc}
    RFX_GPU_TEX_UPLOAD_BL,          // {u32 cmd, u32 tex, u32 level, u32 layer, u8 layout[36], u64 bytes, u32 crc}
    RFX_GPU_SHADER_LOAD,            // {u8 stage, u8 key[8], u8 kind, u16 entry_len, u8 entry[..],
                                    //   u64 blob_len, u32 blob_crc, layout（§4.4）, i32 rc, u32 hid}
    RFX_GPU_SHADER_RELEASE,         // {u32 hid}
    RFX_GPU_PIPE_GET,               // {pipe_desc（§4.5）, u8 mode, i32 rc, u32 hid}
    RFX_GPU_CPIPE_GET,              // {stage_desc（§4.5）, u8 mode, i32 rc, u32 hid}
    RFX_GPU_CMD_BEGIN,              // {u32 occ_slots, u8 has_label, u16 label_len, u8 label[..], i32 rc, u32 hid}
    RFX_GPU_CMD_ABORT,              // {u32 cmd}
    RFX_GPU_PASS_BEGIN,             // {u32 cmd, pass_desc（§4.6）}
    RFX_GPU_PASS_END,               // {u32 cmd}
    RFX_GPU_SET_PIPE,               // {u32 cmd, u32 pipe}
    RFX_GPU_SET_DYN,                // {u32 cmd, dyn（§4.7）}
    RFX_GPU_SET_VBUF,               // {u32 cmd, u32 stream, u32 buf, u64 off}
    RFX_GPU_BIND,                   // {u32 cmd, u8 stage, u32 n, ent[n]（§4.8）}
    RFX_GPU_PUSH,                   // {u32 cmd, u8 stage, u32 off, u32 bytes, u32 crc}
    RFX_GPU_DRAW,                   // {u32 cmd, draw_args（§4.9）}
    RFX_GPU_DISPATCH,               // {u32 cmd, u32 cpipe, u32 x, u32 y, u32 z, u32 ind, u64 ind_off}
    RFX_GPU_COPY_BUF,               // {u32 cmd, u32 src, u64 soff, u32 dst, u64 doff, u64 bytes}
    RFX_GPU_FILL_BUF,               // {u32 cmd, u32 dst, u64 off, u64 bytes, u32 value}
    RFX_GPU_COPY_BUF_TEX,           // {u32 cmd, u32 src, u64 off, u64 row_bytes, u64 image_bytes, u32 tex, u32 level, u32 layer, i32 region[6]}
    RFX_GPU_COPY_TEX_BUF,           // {u32 cmd, u32 tex, u32 level, u32 layer, i32 region[6], u32 dst, u64 off, u64 row_bytes, u64 image_bytes}
    RFX_GPU_COPY_TEX,               // {u32 cmd, u32 src, u32 sl, u32 sa, i32 sreg[6], u32 dst, u32 dl, u32 da, i32 dreg[6]}
    RFX_GPU_BLIT,                   // {u32 cmd, u32 src_view, i32 sreg[6], u32 dst_view, i32 dreg[6], u8 linear}
    RFX_GPU_CLEAR_VIEW,             // {u32 cmd, u32 view, f32 rgba[4], u32 uint4[4], u8 is_int}
    RFX_GPU_BARRIER,                // {u32 cmd, u32 bits}
    RFX_GPU_OCCLUSION,              // {u32 cmd, i32 slot}
    RFX_GPU_LABEL,                  // {u32 cmd, u8 has_text, u16 text_len, u8 text[..]}
    RFX_GPU_CMD_COMMIT,             // {u32 cmd, u64 signal, i32 rc}
    RFX_GPU_FENCE_WAIT,             // {u64 v, u64 timeout_ns, i32 rc}
    RFX_GPU_SURFACE_ATTACH,         // {i32 rc, u32 hid}
    RFX_GPU_SURFACE_REBUILD,        // {u32 surf, i32 rc}
    RFX_GPU_SURFACE_DETACH,         // {u32 surf, u64 timeout_ns, i32 rc}
    RFX_GPU_DRAWABLE_ACQUIRE,       // {u32 surf, u64 timeout_ns, u8 has_plat, i32 rc, u32 view, u32 w, u32 h, u32 fmt, u64 gen, u64 token}
    RFX_GPU_DRAWABLE_RELEASE,       // {u32 surf, u64 gen}
    RFX_GPU_PRESENT,                // {u32 surf, u64 gen, u32 src_view, i32 crop[4], i32 dst[4], u32 filter, f64 at, u64 ticket, i32 rc}
    RFX_GPU_FUNC_N,
    // 不入流的纯查询：caps_get / format_caps / buf_va / buf_cpu / tex_info_get / surface_gen /
    //   fence_done / fence_failed / stats（CHK 覆盖栅栏读数；其余由 FORMAT.md §6 说明）
};

// CHK ckind
enum {
    RFX_CHK_FENCE_DONE = 1,         // {u64 v}
    RFX_CHK_FENCE_FAILED,           // {u64 v}
    RFX_CHK_DONE,                   // {u64 signal, u8 status, i32 rc, u8 time_kind}
    RFX_CHK_BUF,                    // {u32 hid, u64 off, u64 len, u8 bytes[len]}
    RFX_CHK_PRESENTED,              // {u64 ticket, u32 status, f64 at}
    RFX_CHK_RETIRED,                // {u32 hid}
    RFX_CHK_ERROR,                  // {i32 code, u16 entry_len, u8 entry[..], u32 count}
};

// ---------- 写 ----------

typedef struct rfx_w rfx_w;
rfx_w *rfx_w_open(const char *path, uint32_t kind);              // NULL = 打不开
int rfx_w_raw(rfx_w *w, uint32_t tag, const void *payload, uint32_t len);   // 低层：tag + len + payload
int rfx_w_region(rfx_w *w, uint64_t addr, uint64_t len, uint64_t prot);
int rfx_w_data(rfx_w *w, uint64_t addr, const void *bytes, uint64_t len);
int rfx_w_res(rfx_w *w, uint32_t rkind, const char *name, const void *payload, uint32_t len);
int rfx_w_call(rfx_w *w, uint32_t func, uint64_t ret, const void *payload, uint32_t len);
int rfx_w_exp(rfx_w *w, uint32_t func, const void *payload, uint32_t len);
int rfx_w_chk(rfx_w *w, uint32_t ckind, const void *payload, uint32_t len);
int rfx_w_end(rfx_w *w);
int rfx_w_close(rfx_w *w);   // 0 = 完整写完；已写的记录不回滚

// 输入侧逐函数助手（写 CALL 负载；参数为标量，指针类一律先按 FORMAT.md 规范化）
int rfx_call_u32(rfx_w *w, uint32_t func, uint64_t ret, uint32_t a);
int rfx_call_u64(rfx_w *w, uint32_t func, uint64_t ret, uint64_t a);
int rfx_call_none(rfx_w *w, uint32_t func, uint64_t ret);
int rfx_call_sub_index(rfx_w *w, uint32_t func, const uint64_t *h, uint32_t n);
int rfx_call_reg_tex(rfx_w *w, int32_t id, uint64_t tex, const uint8_t view16[16]);
int rfx_call_reg_samp(rfx_w *w, int32_t id, const uint8_t samp_par[40]);
int rfx_call_present(rfx_w *w, uint64_t tex, double period_s, const int32_t crop[4], uint64_t ticket);
int rfx_call_read_texels(rfx_w *w, uint64_t tex, uint32_t level, uint32_t layer0,
                         const int32_t region[6], uint64_t dst, uint64_t row, uint64_t img);

// ---------- 读 ----------

typedef struct {
    uint32_t tag, id;        // id：RES→rkind / CALL,EXP→func / CHK→ckind / 其余 0
    uint64_t off;            // 本记录在文件里的字节偏移（tag 处）
    uint32_t len;            // payload 字节数（含 id 字段自身的记录：len 已含）
    const uint8_t *payload;  // 整条记录负载（含各记录的 func/ckind/rkind 字段）
} rfx_rec;

typedef struct { uint8_t *buf; uint64_t size, pos; uint32_t kind, version; int err; } rfx_r;
int rfx_r_open(rfx_r *r, const char *path);           // 0 = 打开且头合法；失败 err 写明
int rfx_r_next(rfx_r *r, rfx_rec *out);               // 1 = 一条记录；0 = END；-1 = 截断 / 坏格式
void rfx_r_close(rfx_r *r);
int rfx_r_validate_kind(const rfx_r *r);              // 0 = 记录号与本文件 kind 相容

// ---------- 比对 ----------

typedef struct {
    uint32_t index;          // 过滤后序列里的记录序号（从 0）
    uint32_t tag, id;        // 差异所在记录
    uint64_t file_off;       // 差异字节在期望文件里的偏移（-1 = 期望文件先完）
    uint64_t act_off;        // 差异字节在实际文件里的偏移（-1 = 实际文件先完）
    int exp_b, act_b;        // 差异字节值（-1 = 该侧无此字节）
    char msg[192];           // 人读说明（含函数名）
} rfx_diff;

// 期望 vs 实际逐字节比：比对序列 = ASSUME + EXP（CHK 是回放线束断言，不进比对）。
// funcs 非 NULL 时只配对 func 在表内的 EXP 记录（按各自顺序配对）。
// 返回 0 = 一致；非 0 = 第一处差异已写进 *d（msg 里带上下文）。
int rfx_cmp_file(const char *exp_path, const char *act_path,
                 const uint32_t *funcs, uint32_t nfuncs, rfx_diff *d);

// ---------- 杂项 ----------

uint32_t rfx_crc32(const void *p, size_t n);                    // IEEE CRC-32（规范化 blob 用）
const char *rfx_call_name(uint32_t func);
const char *rfx_gpu_name(uint32_t func);
const char *rfx_chk_name(uint32_t ckind);
const char *rfx_res_name(uint32_t rkind);
const char *rfx_tag_name(uint32_t tag);

#ifdef __cplusplus
}
#endif
#endif
