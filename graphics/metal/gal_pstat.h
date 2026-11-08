// 遍序列与 GPFIFO 统计（诊断，NXGAL_PSTAT=1 开，缺省关、零开销）：只统计、不改行为。实现与口径见 gal_pstat.m。
// 本头不含 Metal：单测（tests/t_pstat.c）直接调纯逻辑 gal_pstat_analyze。
#pragma once
#include <stdint.h>

// 一帧里的遍序列事件（渲染线程按发生顺序记进固定环，上屏时回看算账）
enum {
    // 开一个渲染遍（之后紧跟它的各个 PS_ATT）
    PS_PASS = 1,
    // 本遍的一个附件：root = 底层存储编号，clear = 读入动作是清（1）还是读入旧内容（0），bytes = 该附件整遍字节；存回恒为 Store
    PS_ATT = 2,
    // 绘制采样 / 当图像用了 root（cs = 1：计算派发用的）；inpass = 记录时有渲染遍开着（归当前遍），否则归下一个开的遍
    PS_SAMPLE = 3,
    // 其他读到 root 的用法（贴图拷贝源 / 目标、读回、写入、出图源）：一律按「读」算（保守：部分写入要保留旧内容）
    PS_READ = 4,
    // 以下两类只在 NXGAL_PSTAT_DUMP 导出事件流时记（诊断：查断遍原因），root 恒为 UINT32_MAX（算账跳过），bytes = 调用栈表下标
    // 渲染编码器结束
    PS_END = 5,
    // 开拷贝 / 计算编码器
    PS_ENC2 = 6,
};
// view：附件事件的视图标识（视图对象 + mip 级 + 层；0 = 未知），只用来把相邻遍续用拆成同视图 / 不同视图
typedef struct { uint8_t kind, clear, inpass, cs; uint32_t root; uint64_t bytes; uint32_t view; } ps_ev;

typedef struct {
    // 渲染遍数
    uint64_t passes;
    // 附件存回：次数、字节
    uint64_t st_n, st_bytes;
    // 附件读入（load = Load）：次数、字节
    uint64_t ld_n, ld_bytes;
    // 可省存回 ①：存回后、下一次被读之前就被清（下一个事件是以「清」开遍的同一附件）
    uint64_t clr_n, clr_bytes;
    // 可省存回 ②：本帧之后再也没被读（下一帧会不会读不知道，单列）
    uint64_t dead_n, dead_bytes;
    // 相邻遍续用：存回后紧接着下一遍又把它当附件读入（中间没有别的用法）——两遍合一可省这次存回 + 读入
    uint64_t adj_n, adj_st_bytes, adj_ld_bytes;
    // 其中前后两遍是同一视图（同 mip 级、同层）的：只有这部分才可能两遍合一；其余是同一底层贴图的不同 mip / 层
    uint64_t adj_same_n, adj_same_st_bytes;
    // 相邻遍对「本遍写 → 下一遍采样同一附件」（每对遍算一次；只算绘制采样）
    uint64_t pairs;
} ps_res;

// 纯逻辑：一帧事件序列算账，结果累加进 *r（不清零）。不分配；root 必须 < nroot，scratch 至少 nroot × 4 个 uint32_t
void gal_pstat_analyze(const ps_ev *ev, int n, uint32_t nroot, uint32_t *scratch, ps_res *r);

// ---------- 记录点（渲染线程，GAL 入口锁内）：先判 PSTAT_ON()，关时只读一个整数 ----------
// g_pstat：-1 未读环境变量 0 关 1 开
extern int g_pstat;
int gal_pstat_init(void);
#define PSTAT_ON() (g_pstat > 0 || (g_pstat < 0 && gal_pstat_init()))
// 开渲染遍（先于本遍各附件）
void gal_pstat_pass(void);
// 本遍一个附件；slot：0–7 颜色槽、8 深度模板（只进导出，算账不用）
void gal_pstat_att(const void *root, int clear, uint64_t bytes, int slot, uint32_t view);
// 附件视图标识：视图对象地址 + mip 级 + 层折成非 0 的 32 位（同一 root 的两个附件事件比较用；碰撞只会把不同视图误算成同视图，概率可忽略）
static inline uint32_t gal_pstat_view(const void *tex, uint32_t level, uint32_t slice) {
    uint64_t x = (uint64_t)(uintptr_t)tex ^ ((uint64_t)level << 48) ^ ((uint64_t)slice << 32);
    x ^= x >> 29; x *= 0xbf58476d1ce4e5b9ull; x ^= x >> 32;
    return (uint32_t)x | 1u;
}
// kind = PS_SAMPLE / PS_READ
void gal_pstat_use(const void *root, int kind, int inpass, int cs);
// 出图：本帧算账，每 300 帧（NXGAL_PSTAT_EVERY）打一行
void gal_pstat_frame(void);
// 记 PS_END / PS_ENC2（带调用栈）；只在 NXGAL_PSTAT_DUMP 设了时记，否则直接返回
void gal_pstat_mark(int kind);

// ---------- 帧级调度测算（只在 NXGAL_PSTAT_DUMP 导出时登记，否则只读一个整数）----------
// 每个可能切遍的入口登记「切遍原因 + 按调度规则是否真依赖」，收遍时记进 PS_END（clear 字段 = 原因，inpass 字段 = 依赖）。
// 依赖：0 = 可重排（数据更新换新块 / 挪到遍外 / 改读帧缓冲即可不切）1 = 真依赖 2 = 换目标组（遍边界，跨遍合并另算）3 = 游戏要求的提交 4 = 未登记
enum { SW_OTHER, SW_RT, SW_UPLOAD, SW_FILL, SW_BUFCOPY, SW_TEXUP, SW_TEXCOPY, SW_DISPATCH, SW_TEXBAR, SW_MEMBAR, SW_HIDDEN, SW_CLEAR, SW_READBACK, SW_PRESENT, SW_COMMIT, SW_IDXCONV, SW_N };
extern int g_sw_why, g_sw_dep, g_sw_on;
int gal_sw_init(void);
#define SW_ON() (g_sw_on > 0 || (g_sw_on < 0 && gal_sw_init()))
typedef struct { int why, dep; } sw_scope;
static inline void sw_restore(sw_scope *s) { g_sw_why = s->why; g_sw_dep = s->dep; }
// 作用域内登记原因与依赖（出作用域还原外层的）；依赖表达式只在测算开着时求值
#define SW_SCOPE(why, dep) sw_scope _sws __attribute__((cleanup(sw_restore))) = {g_sw_why, g_sw_dep}; if (SW_ON()) { g_sw_why = (why); g_sw_dep = (dep); }
// 本遍用法记账：key = 贴图底层存储指针，或缓冲 SW_BUFKEY(编号)；write = 0 读 1 写
#define SW_BUFKEY(bid) ((const void *)(((uintptr_t)(bid) << 1) | 1))
void gal_sw_note(const void *key, int write);
// 当前遍（开着的渲染遍）里是否读（write = 0）/ 写（write = 1）过
int gal_sw_hit(const void *key, int write);
int gal_sw_pass_open(void);
