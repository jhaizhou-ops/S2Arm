// 宿主补丁装载器（补丁包 v1，设计稿 补丁包_v1设计.md 第 2 / 4 / 12 节）：起局时读 <补丁根>/<程序号>/patch.tsv，数据类段运行时直接生效、不重新出包。
// 补丁根：S2A_PATCH_DIR（Mac 局指本机补丁目录），否则 <Documents>/S2A/patches（iOS = $HOME/Documents，Mac 可用 S2A_DOCS 指，同 envfile.c）。
// 补丁根没有本款 → 读游戏数据目录（资源包根）的 patch.tsv（真机验过的补丁随包，pack/stage_rewrite.sh 拷）；只取一份，补丁根优先。
// 本版宿主读的段：[except] [caps] [widen.verified]（经能力清单 caps.c，同一套优先级）、[widen.enable.<handheld|docked>] [widen.full.<handheld|docked>]（经 widen.c）。
//   [fps]（帧率表行，写成补丁目录 .fps.tsv 经 S2A_FPS_TABLE 交 fps.c，替代包内帧率表）。
//   [data]（正确性类补丁：模块只读数据 / 数据段字节，装载时由 cpatch.c s2a_patch_data_apply 写；无条件生效，不挂 60 帧 / 满屏开关；设计稿 12.12）。
//   [ui] [game] [cpatch.on] 本版不读，日志点名跳过；出包段 [fps.code] [widen.sites] [cpatch] 只在出包时读。
// 优先级（第 12.7 节）：玩家设置 / 启动环境 > [except] > 补丁 [caps] > 包内能力清单 > 宿主缺省；补丁提到的键整键取补丁值。
// 补丁不对号（程序号不同）整份不用；某行坏了只跳那行；读不到补丁 = 通用层，行为与没有本功能时完全一样。
#ifndef S2A_PATCH_H
#define S2A_PATCH_H
#include <stdint.h>

// 满屏启用行：<模块> <偏移> <种类> <启用> [orig=<原指令字 8 位十六进制>] [sig=<前若干字节>|<后若干字节>]（十六进制，?? 通配；点本身 4 字节 = orig，不写进 sig）
typedef struct {
    char mod[32], kind[16];
    uint32_t off, orig;
    int on, has_orig, line, npre, npost;
    uint8_t pre[32], prem[32], post[32], postm[32];   // 特征字节与掩码（掩码 0 = 通配）
} s2a_patch_wrow_t;

// [data] 行：<模块> <偏移> orig=<原字节> new=<新字节，同长> [sig=<前>|<后>]（十六进制，字节按内存顺序；sig 写法同满屏启用行，点本身不写进 sig）
typedef struct {
    char mod[32];
    uint32_t off;
    int line, n, npre, npost;
    uint8_t orig[64], nw[64], pre[32], prem[32], post[32], postm[32];
} s2a_patch_drow_t;
// mod 这个模块的 [data] 行：返回行数，-1 = 补丁没有 [data] 段
int s2a_patch_data_rows(const char *mod, const s2a_patch_drow_t **rows);
// 已写入的 [data] 范围登记 / 查询（满屏的 f32 / aspf / i32 数据点据此避让：重叠时以 [data] 为准、满屏那点跳过）
void s2a_patch_data_mark(const char *mod, uint64_t off, uint64_t n);
int s2a_patch_data_overlap(const char *mod, uint64_t off, uint64_t n);
// 读补丁（每次起局 / 会话重建调一次，先丢上一份）。dir = 模块目录（取 main.npdm 的程序号）。返回 1 = 有对号补丁，0 = 没有。由 s2a_caps_apply 开头调
int s2a_patch_open(const char *dir);
// 能力类行：先 [except]（except = 1）再 [caps]，最后 [widen.verified]（作 widen 1）；回调 cap / val（"0" / "1"）/ why
void s2a_patch_caps_each(void (*fn)(const char *cap, const char *val, const char *why, int except));
// 当前档位（docked 0 / 1）的满屏启用行：返回行数，-1 = 补丁没有这一档的段（走包内启用表）。只给 mod 这个模块的行
int s2a_patch_widen_rows(const char *mod, int docked, const s2a_patch_wrow_t **rows);
// 当前档位 [widen.full.*]：1 / 0，-1 = 补丁没有这一段
int s2a_patch_widen_full(int docked);
// 编写时依据的构建号（文件头 build，32 位小写）；没有补丁返回空串
const char *s2a_patch_build(void);
// 记一条生效结果（进 host.log 与 .applied）
__attribute__((format(printf, 1, 2))) void s2a_patch_note(const char *fmt, ...);
// 装载完写 <补丁目录>/.applied 并打一行汇总（快路径 / 特征命中 / 跳过各几条）；bid = 本包主程序构建号（loader.c s2a_main_build_id）
void s2a_patch_finish(const char *bid);
// 计数：kind 0 = 快路径，1 = 特征命中，2 = 跳过
void s2a_patch_count(int kind);

#endif
