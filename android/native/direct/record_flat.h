// 批次 1 / 模块 A：命令流拍平（A2 延迟参数入记录 + A4 记录内引用重定位）与 A1 捕获分类。
//
// 背景（统一方案 `android/docs/fast-generic-v3.md#totk-chain-design` §④⑤⑥）：
// Android 直连的提交在 `mtl_exec` 就把整条命令链拍平成宿主自有线性记录（mtl_vk_shim.c 的
// g_clone → job_flat → exec_chain → s2a_record_exec_one），游戏随后即可销毁/复用命令内存。
// 但“复制命令字节”不等于“拥有命令引用的数据”，旧实现只做逐字节 memcpy，留下两类缺口：
//   * 记录内指针（snapshots）在副本里仍指向源记录，源内存一释放就是悬垂；
//   * Deferred 绑定的 guest 数组地址在副本里仍是 guest 指针，回放（另一个线程、更晚）才去读，
//     该时点不在任何 NVN 合同窗口内，guest 可已复用该数组。
// 本模块把“提交/拍平”定义为命令数据所有权的转移点：在这里一次性把 guest 数据取进记录，
// 并把记录内引用改写到宿主持有的拍平缓冲。回放（vk_record.c）此后只读拍平记录，不再读 guest
// 命令参数；缓冲内容（UBO/SSBO/顶点/索引/间接参数）仍按 B 模块在真实使用时读，不在本层冻结。
//
// ─────────────────────────── A1：每类参数的“自持 / 延迟 / 执行时读”分类 ───────────────────────────
// 类别          读的时点                         代表记录 / 字段                                 代际判据
// 自持(按值)    录制时                              状态对象(BIND_STATE/VATTR/VSTREAM/VBUF)、       无（字节在该记录内）
//                                                  视口/裁剪/深度范围/模板/混合/alpha ref、绘制参数、
//                                                  清除值/掩码、拷贝区域/步长、程序身份(prog+serial+stages)、
//                                                  普通 UBO/SSBO/顶点/纹理句柄（已按池基址平移）
// 自持(快照)    录制时，且提交拍平时再核一次           tex_t 快照（SET_RT / COPY_* / CLEAR_TEX 的       纹理 serial + magic +
//                                                   tex 指针；记录时对象失效则此处按 guest 对象重读）  描述自洽（A3 消费者分类）
// 延迟(参数)    提交拍平时（本模块）                  Bind*BuffersDeferred 的 NVNbufferRange[]、        数组地址在录制时固定；
//                                                  BindTextures/SeparateTextures/Samplers/ImagesDeferred  句柄值在拍平时取一次
//                                                  的句柄数组、BindTexture 的 BIND_TEX1_AT 设备字
// 执行时读 guest 真实使用时（B 模块）                 addr/size 指向的 UBO/SSBO/顶点/索引/间接绘制参数   B：地址→池/代际/内容版本
// 记录时副作用  录制时（不进记录）                   ResetDeviceMessageBuffer[Deferred]：宿主着色器     无（宿主着色器从不写消息，
//                                                  从不写消息，头恒为 {12,容量,0}，头内容不随时间变） 头值在任何时刻相同）
// 未解码        ——                                  OP_DLSS 等无 Vulkan 解码器的 opcode               回放准确拒绝，不静默跳过
//
// “延迟”一类明确**不是**“回放时再读 guest”：那正是本批要消除的旧行为（旧 vk_record.c 的
// BIND_BUF_DEFER / rec.defer 分支）。拍平后的记录里这些字段已是自持值；旧分支只在测试直接
// 构造未拍平记录时可达。NVN 语义允许游戏在录制后、提交前改写句柄数组（旷野之息逐纹理 Deferred
// 绑定即如此），因此读取点必须落在“提交/拍平”而不是更晚；见 `graphics/nvn/docs/deferred_texture_pools.md`
// 的实测（录制后改句柄 → 期望按改写后的值）。
//
// 使用约束：
//   * 只改 Android Vulkan 模块；共享记录层 graphics/nvn/** 的布局不变，本模块按 nvn_obj.h 读写同一份格式。
//   * 单线程：调用方在 mtl_exec（guest 线程、同一时刻一个打开提交）里调用；不分配 Vulkan 对象。
//   * 拍平失败（guest 数据不可读 / 记录自相矛盾）必须让整笔提交不发布完成证明，不能丢命令还发 fence。
//   * 未知 opcode 原样拷贝：它们不含记录内快照指针（A1 表已逐类核对）；真正不支持的 opcode 由回放
//     准确拒绝。任何新增“记录内含指向记录内快照的指针”的格式，必须同批扩展本模块与合同测试。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 与 vk_record.h 的 s2a_record_code 同值（本模块不依赖 Vulkan 头，宿主可独立编译）。
enum {
    S2A_RECORD_FLAT_OK = 0,
    S2A_RECORD_FLAT_INVALID = -2,
    S2A_RECORD_FLAT_UNSUPPORTED = -3,
    S2A_RECORD_FLAT_MEMORY = -5,
};

// 把一条记录（op_hdr + payload，size = op_hdr.size，8 字节对齐）拍平写入 dst。
// record 只读；dst 至少 size 字节（本模块不改变记录大小）。返回 0 成功；负数为 S2A_RECORD_* 错误码：
//   S2A_RECORD_INVALID(-2)：记录结构自相矛盾（长度/计数/字段越界）
//   S2A_RECORD_MEMORY(-5)：延迟参数/失效快照的 guest 数据不可读，无法证明捕获
//   S2A_RECORD_UNSUPPORTED(-3)：记录引用了本模块不认识的记录内引用（防静默悬垂）
// why/why_size 写入失败原因（可为 NULL）。
int s2a_record_flat_write(const uint8_t *record, size_t size, void *dst, char *why, size_t why_size);

// 只判断一条记录是否会改变大小/是否受支持（当前恒等于 size；保留给“内联数据”扩展）。
size_t s2a_record_flat_size(const uint8_t *record, size_t size);

// ---- 追加式拍平缓冲（模块自有；生产路径用这三个入口） ----
//
// 为什么缓冲由本模块持有：拍平要在记录里写入“宿主自有快照”的**地址**，而一条命令链有成千上万条记录，
// 缓冲必须随追加增长（realloc）。若由调用方给一块固定 dst，后面每次增长都会让先前写进去的地址悬垂：
// 真机实测（TOTK 标题画面，2026-11-07）就是 rt 快照指针读成全零 → 颜色附件格式缺失 →
// `fragmentOutputTypes` 被编译器判 MISSING_FIELD → 首笔图形 draw 报红并中止。
// 因此地址只能等“缓冲不再移动”之后再落：追加时登记（字段偏移, 快照偏移），take 时一次写成真实地址。
//
// 用法（生产 = mtl_vk_shim.c 的三个调用点，每个只替换原有缓冲记账，不新增逻辑）：
//   s2a_record_flat_reset();
//   for each record:  if (s2a_record_flat_append(rec, size, NULL, 0)) -> 整笔提交不发布完成证明；
//   buf = s2a_record_flat_take(&len);   // 所有权交给调用方（malloc 块，调用方 free）；NULL = OOM
void s2a_record_flat_reset(void);
int s2a_record_flat_append(const uint8_t *record, size_t size, char *why, size_t why_size);
// 定稿：把登记的记录内引用写成最终地址，交出缓冲所有权并清空本模块状态。NULL = 分配失败（准确失败）。
uint8_t *s2a_record_flat_take(size_t *len);

#ifdef __cplusplus
}
#endif
