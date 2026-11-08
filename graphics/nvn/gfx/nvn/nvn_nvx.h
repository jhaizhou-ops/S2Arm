// NVX 扩展入口（hle_nvn.c「驱动 GetProcAddress 名字全集里的 NVX / 私有入口」段）记在 NVN 对象保留区里的状态：接在 nvn_obj.h 的基本结构之后。
// 单放一个头、不改 nvn_obj.h：nvn_obj.h 进直连库阶段键（pack/stage_inputs/direct.tsv「入」），改它会让所有款的直连库冷出；这些字段只有宿主运行时读写。
#pragma once
#include "nvn_obj.h"

// DeviceBuilderSetReservedAddressRangesNVX 的个数与区间数组（只记下、读回）。DeviceBuilderSetDefaults 按本结构整个清零
typedef struct { dev_builder_t b; int32_t nres; const void *res; } dev_builder_x;                FITS(dev_builder_x, NVNdeviceBuilder);
// native: MemoryPoolBuilderSetNativeHandleNVX 的 nvmap 句柄（与 SetStorage 互斥，同真机）；res_*: Set{Pitch,BlockLinear,Special}AddressNVX 预留的 GPU 地址。SetDefaults 按本结构整个清零
typedef struct { pool_builder_t b; int32_t native; uint64_t res_pitch, res_bl, res_sp; } pool_builder_x;   FITS(pool_builder_x, NVNmemoryPoolBuilder);
// bl_va / sp_va: 构建器预留的块线性 / 特殊映射地址（MemoryPoolGet{BlockLinear,Special}AddressNVX 读回；本层没有这两种映射，没预留就是 0）。MemoryPoolInitialize 写
typedef struct { pool_t p; uint64_t bl_va, sp_va; } pool_x;                                     FITS(pool_x, NVNmemoryPool);
// rm: NVN_SYNC_RM = 由 nvnSyncInitializeFromNvRmSyncNVX 建（真机类型 5，只有它带 host1x syncpoint，Sync{Get,Set}SyncpointsNVX 只认它）；各个同步对象初始化入口都写
typedef struct { sync_t s; uint32_t rm; } sync_x;                                               FITS(sync_x, NVNsync);
#define NVN_SYNC_RM MAGIC('N', 'V', 'R', 'M')
// QueueSetTimeoutNVX / QueueSetTimesliceNVX 记下的值（本层没有 GPU 通道可设，只读回）。QueueInitialize 清零
typedef struct { queue_t q; uint64_t timeout_ns; uint32_t timeslice_us; } queue_x;              FITS(queue_x, NVNqueue);
