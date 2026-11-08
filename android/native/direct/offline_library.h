// F5.3：安装 revision 内离线程序库的只读消费者（运行时新模块）。
//
// 包内布局（实施契约 §8、统一方案 §4.1 第 5/6 步与 §5.3，生产端 = tools/direct_library.py）：
//   <revision>/shaders/vulkan/direct/<directABI>/<profileHash>/<identity>.program
// 每个 .program 是 S2APC1 v2 容器（与私有缓存 native/direct/program_cache.c 同一格式）：
// 88 B 头 = magic/version/header/identity/result SHA-256/负载长度，后接 s2a-direct-program-v1 字节。
//
// 身份载体选 **(a) 设备导出的完整身份**，条目不自带 request：
//   * 设备在 nvn_vk_draw.c 用 S2AI1 v3 规范输入算完整 SHA-256（insha），捕获侧把它写成条目名；
//     宿主机无法仅凭 request 复算（request 已去掉 0x30 图形头，身份还含全部真实事实）。
//   * 因此定位只需要调用方手里已有的两半：完整身份（文件名 + 容器内部身份）和本局请求的
//     directABI/profileHash（目录）。session/generation/requestId 是 transport 身份，**不进入
//     本接口**：拿另一局的 transport 当跨局键会永远不命中（方案 §5.5.2 第 8 条）。
//
// 只读与冻结：从 revision 根逐级 openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW) 下钻，条目本身用
// O_NOFOLLOW|O_NONBLOCK 打开，只 read/close；不建目录、不写、不删、不“修复”坏条目。安装
// revision（根路径由调用方给出，按可信处理）在任意次数读取前后必须逐文件不变；坏条目留在
// 原地、每次都拒绝，删除属于维护操作。（宿主用例 direct_offline_library_test.c 的冻结用例）
//
// 命中判据不是“文件已打开”：文件名身份 = 容器内部身份 = 请求身份，头部长度 = 磁盘长度，
// 负载 SHA-256 = 头部摘要，全部成立才返回字节。返回的字节**尚未**做内容语义解析：schema/
// 阶段/SPIR-V/反射/SupportBuffer 布局的接受仍由现有 nvn_vk_first_draw.c 的 parse_program
// 负责，命中不等于可绘制（统一方案 §4.1 第 6 步“不能仅靠文件已打开判命中”）。
//
// 线程与生命周期：可并发调用；模块无全局可变状态，计数器是原子量。bytes 的所有权交给调用方
// （free）。revision_root 必须是非空绝对路径，profile_hash 只借用、只需在调用期间有效。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 一笔请求里“定位离线库”需要的那一半身份。完整 S2AI1 v3 身份（identity）是键，directABI/
// profileHash 决定目录；调用方还须确认 live profile 列在描述符的离线目标中。
struct s2a_offline_request {
    uint8_t identity[32];        // S2AI1 v3 内容身份（64 位小写 hex 的文件名 + 容器内部身份）
    uint32_t direct_abi;         // 本实现的 directABI（十进制目录名）；0 = 调用方没填
    const char *profile_hash;    // 本局 effective profile 的 "sha256-"+64 小写 hex
    int profile_declared;        // 描述符列出此 profile 才可读取；否则算离线未命中
};

// 命中产物。bytes 由 malloc 给出，调用方负责 free；len 是结果字节数（不含 88 B 容器头）；
// result_sha 是已校验的负载 SHA-256（读时已算过，复用方不必重算）。
struct s2a_offline_program {
    uint8_t *bytes;
    size_t len;
    uint8_t result_sha[32];
};

enum {
    S2A_OFFLINE_HIT = 0,        // 命中，产物已填好
    S2A_OFFLINE_MISS = 1,       // 该身份在库目录里不存在（或 revision 根本没有 direct 目录）
    S2A_OFFLINE_REJECT = -1,    // 找到了但不能用：容器损坏/身份不符/摘要不符/不可读/非普通文件等
    S2A_OFFLINE_INVALID = -2,   // 调用方参数错（未访问文件；不计入任何计数）
};

// 按 <revision_root>/shaders/vulkan/direct/<directABI>/<profileHash>/<identity>.program 定位并
// 校验。返回 S2A_OFFLINE_*；why 写入准确原因（可传 NULL）。未命中/拒绝时 out 被清零。
int s2a_offline_library_fetch(const char *revision_root, const struct s2a_offline_request *request,
                              struct s2a_offline_program *out, char *why, size_t why_size);

// 计数口径：
//   offline_hit    — 通过全部校验并返回字节；
//   offline_miss   — live profile 未列出，或条目/某一级库目录不存在（ENOENT）；
//   offline_reject — 找到了但不可接受：容器 magic/版本/长度损坏、内部身份或负载摘要不符；
//                    路径经过链接、某一级不是目录、条目不是普通文件；打开失败、分配失败。
// 参数错误（INVALID）不计数：那是调用方 bug，不是库的状态。
uint64_t s2a_offline_hits(void);
uint64_t s2a_offline_misses(void);
uint64_t s2a_offline_rejects(void);

#ifdef __cplusplus
}
#endif
