// 外置镜像包（通用映射加载器，11-03 起；11-04 全外置后是游戏镜像的唯一形态）：游戏模块镜像不编进主程序，写成包内一个签名 dylib（iOS：<App>/Frameworks/S2AImages.dylib，
//   dyld 不装、主程序不链接），运行时按需把某个镜像的代码块 / 可写块 MAP_FIXED 映射到调用方给的地址。接口说明见 docs/接口_原生层.md「外置镜像包」。
// 文件格式 = ios/embed.py 的合并布局（纯 Python 写 Mach-O，自带预留签名区）：代码块依次在 __TEXT,__swcode、可写块在 __SWDATA,__img、偏移表在 __TEXT,__swidx
//   （魔数 "S2AEMB01"、u32 项数、u32 项长 88；每项 = 名字 24 字节 + 4 ×（u64 节内偏移, u64 长度），块序 x0 / W / x1 / x2）。
// 只在 Apple 平台编（安卓的模块映射走 APK 资源）。线程：open 内部加锁、只做一次；find / map / same 只读包状态，可并发
#pragma once
#include <stddef.h>
#include <stdint.h>

enum { S2A_IMG_X0 = 0, S2A_IMG_W = 1, S2A_IMG_X1 = 2, S2A_IMG_X2 = 3 };   // 块号（偏移表每项 4 块的顺序，与 ios/embed.py 一致）
enum {   // 返回码（0 = 成功）
    S2A_IMG_OK = 0,
    S2A_IMG_ENOFILE = 1,   // 包文件不存在（本款没有外置镜像：调用方按「没有」处理，不是错）
    S2A_IMG_EFORMAT = 2,   // 不是 64 位 Mach-O / 缺节 / 偏移表魔数、项长、16K 对齐、越界、重叠不符
    S2A_IMG_ESIGN = 3,     // 签名注册（F_ADDFILESIGS_RETURN）或库校验（F_CHECK_LV，要同团队签名）失败
    S2A_IMG_EMAP = 4,      // mmap 没落在要的地址（errno 见 s2a_imgpack_map 的 *err：iOS 上盖已有代码页 / 已释放的代码页是 EACCES）
    S2A_IMG_EPROT = 5,     // 代码页压最大权限到 R|X 失败
};
typedef struct s2a_imgpack s2a_imgpack;
// 打开包：open（fd 常开到进程结束）+ pread 读头与偏移表 + 注册签名一次 + 库校验。同一路径重复调用回同一个包（进程内只注册一次）。
//   成功回 S2A_IMG_OK、*out 置包；失败回错误码、why（可空）写一行原因
int s2a_imgpack_open(const char *path, s2a_imgpack **out, char *why, size_t whyn);
// 只读头与偏移表（不注册签名、不进上面「同一路径回同一个包」的表、fd 读完即关）：多款容器构造期按各款镜像包的 x1 块长算窗口需求用
//   （runtime/src/vawin.c → loader.c s2a_loader_span_images；玩家还没选游戏，不给没选的款注册签名）。读的字节 = Mach-O 头 32 + load commands + 偏移表 16 + 88 × 项数。
//   只能 find，不能 map / same；用完 s2a_imgpack_free。返回码同 s2a_imgpack_open（不会有 S2A_IMG_ESIGN）
int s2a_imgpack_index(const char *path, s2a_imgpack **out, char *why, size_t whyn);
void s2a_imgpack_free(s2a_imgpack *p);   // 只释放 s2a_imgpack_index 的结果；s2a_imgpack_open 的包常驻到进程结束
// 按镜像名查块：找到这个镜像回 1（*off = 块在包文件里的绝对偏移、*len = 块长；长度 0 = 这一块为空：无补丁点的 x1、无双岛的 x2），没有这个镜像回 0
int s2a_imgpack_find(const s2a_imgpack *p, const char *name, int blk, uint64_t *off, uint64_t *len);
// 把包里 [off, off + len) 私有映射到 at（MAP_FIXED，at / off / len 都要 16K 对齐）：code = 1 映射成 R|X 并把最大权限压到 R|X（此后谁 mprotect 成可写当场
//   EACCES，同签名 __TEXT；不压的话 iOS 允许 mprotect(R|W)，代码页从此丢执行权、再也改不回）；code = 0 映射成 R|W（写时复制，换回干净副本 = 再映射一次）。
//   *err（可空）回 errno。代码页语义（iOS 实测，11-03 测试机2）：映射后不能释放、不能覆盖——munmap 回 0 但留下「权限 0 / 最大 0」的占位，
//   再往这个地址映射任何东西 EACCES；所以同一镜像卸了再装要原地复用代码页、只重映可写块（loader.c remap_writable），进程内重启同理（s2a_imgpack_same）
int s2a_imgpack_map(const s2a_imgpack *p, void *at, uint64_t off, uint64_t len, int code, int *err);
// at 处已映射、可读的 len 字节与包里 [off, off + len) 逐字节相同回 1（进程内重启 / 落点复用前核内容）；有没映射 / 不可读的段、读包失败或不同回 0
int s2a_imgpack_same(const s2a_imgpack *p, const void *at, uint64_t off, uint64_t len);
// 一个段（vm_region 的当前 / 最大权限）算不算代码页：最大权限「可执行不可写」（签名 __TEXT 共享来的页、s2a_imgpack_map 压过最大权限的外置页、Mac 装载器 seal_rx 封的页），
//   iOS 上再加「当前权限含执行」兜底（外置文件页映射出来最大权限是 rwx，11-03 测试机2 实测；万一没压成也认得出。iOS 窗口里不会有别的可执行页）。
//   Mac 不加这条：客体可以 SetMemoryPermission 出当前 r-x、最大 rwx 的普通页，进程内重启要照常盖掉它们。
//   iOS 上代码页盖不掉，窗口复位 / 落点选择都要绕开（vawin.c s2a_window_session_reset、loader.c span_has_signed_code）
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
static inline int s2a_prot_is_code(int prot, int max_prot) {   // 4 = VM_PROT_EXECUTE、2 = VM_PROT_WRITE
#if defined(__APPLE__) && TARGET_OS_IPHONE
    if (prot & 4) return 1;
#endif
    (void)prot; return (max_prot & 4) && !(max_prot & 2);
}
#if defined(__APPLE__)
#include <mach/mach.h>
// [lo, hi) 里有没有代码页（判据同上）
static inline int s2a_span_has_code(uint64_t lo, uint64_t hi) {
    vm_address_t a = (vm_address_t)lo;
    while (a < hi) {
        vm_address_t r = a; vm_size_t sz = 0; natural_t depth = 0; vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &r, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS || r >= hi) return 0;
        if (s2a_prot_is_code(info.protection, info.max_protection)) return 1;
        a = r + sz;
    }
    return 0;
}
#endif
