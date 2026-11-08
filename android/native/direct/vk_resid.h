// 资源身份账本 + VM 替页事务（纯逻辑，宿主可测，不碰 Vulkan/AHB/VM）。
//
// 为什么单独一层：直连这边「guest 地址 → 可给 GPU 用的缓冲」的映射会被迁移（换 AHB 后备页），
// 而地址相同、长度相同**不能**证明还是同一资源、更不能证明内容没变（实测同址已变 ≈660 次/帧）。
// 所以每次查找返回的引用要带「后备身份 + 映射代际 + 内容版本」，使用前再校验一次；
// 迁移本身要在一个事务里完成：排空写入 → 保住旧映射可回滚 → 换映射 → 重建页保护与状态 → 发布 → 旧资源等 fence 完成再退休。
//
// 本文件只做账本与事务编排；真正的 mmap/mprotect/vkAllocateMemory 由注入的 ops 执行，
// 于是所有失败路径与回滚都能在宿主上确定性地测（含每个阶段注入失败）。
//
// 并发合同：本层**自带一把互斥锁**（保护全部账本状态），入口可从绘制线程（lookup / ref_valid）、
// guest 线程（FlushMappedRange → note_write）、帧完成点（ref_commit_backing / complete / retire）与
// VM owner 窗口（migrate）并发调用。`S2A_RES_EBUSY` 只表示“同一个线程重入迁移事务”。
// 注意：`s2a_res_migrate` 持锁期间会调用注入的 ops（可能是几十 MB 的 memcpy 与 mmap），
// ops 回调里**不能**再回调本层（锁非递归），也不能长时间阻塞。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 未指定 out 参数时按「不需要」处理。
#define S2A_RES_OK 0
#define S2A_RES_EINVAL 1
#define S2A_RES_ENOSPC 2      // 账本满
#define S2A_RES_ENOENT 3      // 没有覆盖该范围的受管范围
#define S2A_RES_ESTALE 4      // 引用已过期（代际/后备/范围不匹配）
#define S2A_RES_EBUSY 5       // 已在迁移事务中（重入）；本层**没有锁**，只在 VM owner 窗口的单线程里调用
#define S2A_RES_ENOTSUP 6     // 该范围不允许迁移（未对齐/跨池/多别名/未证明归属）
#define S2A_RES_EIO 7         // 注入或底层操作失败（已完整回滚，旧映射仍有效）
#define S2A_RES_EFATAL 8      // 回滚也失败：旧映射不可恢复，调用方必须终止（合同要求，不能继续画）

enum s2a_res_kind { S2A_RES_KIND_UPLOAD = 0, S2A_RES_KIND_SHARED = 1 };
enum s2a_res_state { S2A_RES_FREE = 0, S2A_RES_LIVE = 1, S2A_RES_RETIRED = 2 };

// 一次查找的结果：使用方必须拿它在使用前再校验（s2a_res_ref_valid）。
struct s2a_res_ref {
    uint64_t backing_id;      // 后备对象身份（单调递增，永不复用）
    uint64_t gen;             // 映射代际：换底/重建 +1
    uint64_t offset;          // 该地址在范围内的偏移
    uint64_t len;             // 本次请求长度
    uint64_t content_version; // 内容版本（写跟踪/常量更新会 +1）
};

// 底层操作（宿主测试注入；生产实现走 mmap/mprotect/vk*）。
struct s2a_res_ops {
    void *ctx;
    int (*track_begin)(void *ctx, uint64_t addr, uint64_t size, uint64_t source);
    void (*track_end)(void *ctx, uint64_t addr, uint64_t size, int mapped, int committed);
    int (*prepare_backing)(void *ctx, uint64_t len, uint64_t *out_backing_id);   // 分配新后备（AHB）
    int (*copy_content)(void *ctx, uint64_t addr, uint64_t backing_id, uint64_t len);  // 旧内容搬进新后备
    int (*remap)(void *ctx, uint64_t addr, uint64_t len, uint64_t backing_id);   // 事务内替换映射
    int (*rebuild_protection)(void *ctx, uint64_t addr, uint64_t len);           // 重建页保护/写跟踪
    int (*publish)(void *ctx, uint64_t addr, uint64_t len);                      // 让新映射对外可见
    // 回滚到旧映射：返回 0 = 旧映射已完整恢复（字节/权限/元数据），非 0 = 无法恢复。
    int (*rollback_map)(void *ctx, uint64_t addr, uint64_t len);
    void (*release_backing)(void *ctx, uint64_t backing_id);                     // 释放新后备（失败回滚时）
};

// 账本
void s2a_res_reset(void);
// 登记一段受管范围（页对齐、len>0）。同一地址必须先把旧的 retire。
int s2a_res_register(uint64_t addr, uint64_t len, uint64_t pool_id, uint64_t backing_id, uint64_t *out_gen);
// 查找覆盖 [addr, addr+len) 的受管范围；返回引用（含代际与内容版本）。
int s2a_res_lookup(uint64_t addr, uint64_t len, struct s2a_res_ref *out);
// 使用前校验：引用必须与当前账本一致（代际/后备/偏移未变）。
int s2a_res_ref_valid(const struct s2a_res_ref *ref);
// 内容版本 +1（写跟踪通知 / 有条有序的常量更新）。
int s2a_res_note_write(uint64_t addr, uint64_t len);
// 立即停止新命中；在途引用仍按提交序号保活。
int s2a_res_retire(uint64_t addr, uint64_t len);
// 在途保活：ref_commit 记录一次提交引用了该范围；complete 表示该提交的 fence 已完成。
int s2a_res_ref_commit(uint64_t commit_seq, uint64_t addr, uint64_t len);
// 对象级保活：同一提交对同一后备只登记一次（幂等）。逐段登记会在 128 槽上限撞墙并退化成
// “每两帧放出一批名额”，实测把零拷贝采用率压在 64 次/帧。
int s2a_res_ref_commit_backing(uint64_t commit_seq, uint64_t backing_id);
int s2a_res_complete(uint64_t commit_seq);
// 该后备是否还有未完成的引用（未完成则不得销毁）。
int s2a_res_backing_busy(uint64_t backing_id, int *out_busy);

// 迁移事务：把 [addr, addr+len) 换到新后备。要求整段落在同一个受管范围内、页对齐、
// 该范围没有多别名（spec: source != 0 一律拒绝，本函数只支持单映射）。
// 成功返回 S2A_RES_OK，范围代际 +1；任何阶段失败都会回滚（映射/保护/账本）并返回错误码。
int s2a_res_migrate(const struct s2a_res_ops *ops, uint64_t addr, uint64_t len,
                   uint64_t source_alias, uint64_t *out_gen);

// 常量版本化（第一阶段用它保证「写入 7 → Draw A → 写入 11 → Draw B」得到 A=7、B=11）：
// 每次更新是不可变 payload；draw 按自己的命令序号绑定它之前最后一次更新的版本。
// 这正是 NVN UpdateUniformBuffer 的语义（命令位置上的有序更新），不能用“立即写 CPU 内存”代替。
int s2a_res_ubo_write(uint64_t draw_seq, const void *data, size_t len);
int s2a_res_ubo_resolve(uint64_t draw_seq, const void **out_data, size_t *out_len);
void s2a_res_ubo_reset(void);

// 诊断：供测试与窗口日志用。
struct s2a_res_stats {
    uint64_t migrations_ok, migrations_fail, rollbacks, stale_hits, notsup, refs_committed, backs_busy;
    uint64_t completes_noop;   // 重复完成（幂等命中空集）的次数
};
void s2a_res_stats_get(struct s2a_res_stats *out);

#ifdef __cplusplus
}
#endif
