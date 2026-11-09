// 页值显隐探针实现（接口与诚实标注见 vpad_probe.h）。
// 模块表经 dlsym 运行时取（loader.c 的 g_mod / g_nmod）：不链装载器的目标（单测 / 工作台）取不到就当没有模块，
//   探针永远不发布，vpad 保持战斗布局。读内存只经下面三个带对齐检查的读数口 + nxn 同款守卫
//   （类 ready 标志、statics / 实例非空、实例 +0x10 非空、标量值域），任何一步不合规都按「读不到」处理。
#import "vpad_probe.h"
#import "vpad_data.h"
#include "native.h"   // module_t 布局与 LOG
#include <dlfcn.h>
#include <pthread.h>
#include <time.h>
#include <stdatomic.h>
#include <string.h>
#include <strings.h>

static uint64_t cfg_num(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [value unsignedLongLongValue];
    if ([value isKindOfClass:NSString.class]) return strtoull([value UTF8String], NULL, 0);
    return UINT64_MAX;
}
static BOOL rd64(uint64_t addr, uint64_t *out) {
    if (!addr || (addr & 7)) return NO;
    *out = *(const uint64_t *)(uintptr_t)addr; return YES;
}
static BOOL rd32(uint64_t addr, uint32_t *out) {
    if (!addr || (addr & 3)) return NO;
    *out = *(const uint32_t *)(uintptr_t)addr; return YES;
}
static BOOL rd8(uint64_t addr, uint8_t *out) {
    if (!addr) return NO;
    *out = *(const uint8_t *)(uintptr_t)addr; return YES;
}

// ---- 模块表（dlsym 一次，之后每轮现读指针：模块表起局后不再搬家，见 native.h）----
static module_t **s_mod_table; static int *s_mod_count;
static void mod_table_resolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_mod_table = (module_t **)dlsym(RTLD_DEFAULT, "g_mod");
        s_mod_count = (int *)dlsym(RTLD_DEFAULT, "g_nmod");
    });
}
static module_t *mod_named(const char *want) {   // 精确名（如 main）
    mod_table_resolve();
    if (!s_mod_table || !s_mod_count || !*s_mod_table) return NULL;
    for (int i = 0; i < *s_mod_count; i++) {
        char name[17]; memcpy(name, (*s_mod_table)[i].name, 16); name[16] = 0;
        if (!strcmp(name, want)) return &(*s_mod_table)[i];
    }
    return NULL;
}
static module_t *mod_containing(const char *needle) {   // 名含子串（不分大小写；NRO 名在 16 字里截断，按子串认）
    mod_table_resolve();
    if (!s_mod_table || !s_mod_count || !*s_mod_table) return NULL;
    for (int i = 0; i < *s_mod_count; i++) {
        char name[17]; memcpy(name, (*s_mod_table)[i].name, 16); name[16] = 0;
        if (strcasestr(name, needle)) return &(*s_mod_table)[i];
    }
    return NULL;
}
static module_t *main_module(void) {
    module_t *m = mod_named("main");
    if (m) return m;
    mod_table_resolve();
    return s_mod_table && s_mod_count && *s_mod_count > 0 ? &(*s_mod_table)[0] : NULL;
}

// IL2CPP 单例链（nxn hle_hid.c 同款）：槽 → 类对象（+0xe4 ready 标志、+0xb8 statics 指针）→ 实例（statics + 偏移），
//   实例有效 = 实例 +0x10 指针非空。0xe4 / 0xb8 / 0x10 是 IL2CPP 类布局常量，不是某款游戏的数字。
static BOOL il2cpp_instance(module_t *m, uint64_t slot, uint64_t instanceOffset, uint64_t *out) {
    if (!m || slot == UINT64_MAX || slot + 8 > m->size) return NO;
    uint64_t klass, statics, instance, probe;
    if (!rd64((uint64_t)m->base + slot, &klass) || !klass) return NO;
    uint8_t ready;
    if (!rd8(klass + 0xe4, &ready) || !ready) return NO;
    if (!rd64(klass + 0xb8, &statics) || !statics) return NO;
    if (!rd64(statics + instanceOffset, &instance) || !instance) return NO;
    if (!rd64(instance + 0x10, &probe) || !probe) return NO;
    *out = instance; return YES;
}

@interface S2AVPadProbe ()
- (void)pollOnce;
- (BOOL)running;
@end
static void *s2a_probe_thread(void *ctx) {
    S2AVPadProbe *probe = (__bridge_transfer S2AVPadProbe *)ctx;
    while ([probe running]) {
        [probe pollOnce];
        struct timespec ts = {0, 100 * 1000 * 1000};   // 10 Hz（同 nxn watcher）
        nanosleep(&ts, NULL);
    }
    return NULL;
}

@implementation S2AVPadProbe {
    NSDictionary *_classes;      // il2cpp-singletons：类名 → 配置条目
    _Atomic int _mode;           // 发布值：-1 未派生、-2 读不到、>= 0 模式
    pthread_t _thread;
    _Atomic int _run;
    int _lastLogged[4];          // 上次记进日志的 (gs, us, page, mode) / (diary, pause, mode)
}
+ (instancetype)probeForTitleID:(NSString *)titleID {
    if (!titleID.length) return nil;
    NSDictionary *config = [S2AVPadData jsonForRelativePath:[NSString stringWithFormat:@"visibility/%@.json", titleID]];
    if (!config || ![config[@"reader"] isKindOfClass:NSString.class]) return nil;
    S2AVPadProbe *probe = [self new];
    probe->_config = [config copy]; probe->_titleID = [titleID copy];
    probe->_status = [config[@"status"] isKindOfClass:NSString.class] ? [config[@"status"] copy] : @"unverified";
    atomic_init(&probe->_mode, -1); atomic_init(&probe->_run, 0);
    memset(probe->_lastLogged, 0xff, sizeof probe->_lastLogged);
    if ([config[@"reader"] isEqualToString:@"il2cpp-singletons"]) {
        NSMutableDictionary *classes = [NSMutableDictionary dictionary];
        for (NSDictionary *entry in [config[@"classes"] isKindOfClass:NSArray.class] ? config[@"classes"] : @[])
            if ([entry[@"name"] isKindOfClass:NSString.class]) classes[entry[@"name"]] = entry;
        probe->_classes = [classes copy];
    }
    return probe;
}
- (NSDictionary *)modeEntry:(int)mode {
    NSDictionary *modes = [_config[@"modes"] isKindOfClass:NSDictionary.class] ? _config[@"modes"] : nil;
    id entry = modes[[NSString stringWithFormat:@"%d", mode]];
    return [entry isKindOfClass:NSDictionary.class] ? entry : nil;
}
- (BOOL)sticksEnabledForMode:(int)mode {
    NSDictionary *entry = [self modeEntry:mode];
    if (!entry) return YES;
    if ([entry[@"sticks"] isKindOfClass:NSNumber.class]) return [entry[@"sticks"] boolValue];
    id keys = entry[@"keys"];
    return !([keys isKindOfClass:NSArray.class] && ![keys count]);   // 键集为空的模式（过场 / 全隐藏）摇杆也不响应
}
- (int)currentMode { return atomic_load(&_mode); }
- (void)start {
    if (atomic_exchange(&_run, 1)) return;
    LOG("触屏显隐：探针启动 %s（reader %s，状态 %s）", _titleID.UTF8String,
        [_config[@"reader"] UTF8String], _status.UTF8String);
    void *ctx = (void *)CFBridgingRetain(self);
    pthread_create(&_thread, NULL, s2a_probe_thread, ctx);
}
- (void)stop { atomic_store(&_run, 0); }
- (BOOL)running { return atomic_load(&_run) != 0; }
- (void)dealloc { [self stop]; }
- (void)pollOnce {
    int mode = -2;
    NSString *reader = _config[@"reader"];
    if ([reader isEqualToString:@"il2cpp-singletons"]) mode = [self pollIL2CPP];
    else if ([reader isEqualToString:@"module-data-fields"]) mode = [self pollDataFields];
    atomic_store(&_mode, mode);
}
// 丝之歌派生（nxn slim-139 定版逐条对齐；页值表在配置 menuPages / achievementsPage / bindingPage）：
//   gs==7 或 us==3 → 2（输入处理器可解且 skip ∈ {0,1} → 3 可跳过过场）；gs∈{2,3,6} 或 us==2 → 1（全隐藏）；
//   gs==5 且 page==20 → 6（局内键位页全键）；gs==5 其余 → 5（精简）；gs==1 且 page ∈ 菜单页集 → 5、
//   page==13（功绩）→ 7（只 B）、page==20 → 6；bagEnabled 且 gs==4 且 inv==1 → 4（背包，本批配置关）；其余 → 0（战斗）。
//   已知门：gs ∈ [0,7] 且 us ∈ [0,6] 才算派生得出；之外按读不到（-2）。
- (int)pollIL2CPP {
    NSString *want = [_config[@"buildID"] isKindOfClass:NSString.class] ? _config[@"buildID"] : nil;
    if (want.length) {   // 构建门控：槽位 / 偏移只对逆向时那一版有效，构建号对不上就不发布（同 nxn 的 build 检查）
        const char *bid = s2a_main_build_id();
        if (!bid || strncasecmp(bid, want.UTF8String, want.length)) return -2;
    }
    module_t *main = main_module(); if (!main) return -2;
    NSDictionary *gm = _classes[@"GameManager"], *um = _classes[@"UIManager"];
    if (!gm || !um) return -2;
    uint64_t gmInst, umInst;
    if (!il2cpp_instance(main, cfg_num(gm[@"slot"]), cfg_num(gm[@"instanceOffset"]), &gmInst)) return -2;
    if (!il2cpp_instance(main, cfg_num(um[@"slot"]), cfg_num(um[@"instanceOffset"]), &umInst)) return -2;
    NSDictionary *gmF = [gm[@"fields"] isKindOfClass:NSDictionary.class] ? gm[@"fields"] : nil;
    NSDictionary *umF = [um[@"fields"] isKindOfClass:NSDictionary.class] ? um[@"fields"] : nil;
    if (!gmF || !umF) return -2;
    uint32_t gs, us, page = 0;
    if (!rd32(gmInst + cfg_num(gmF[@"gs"]), &gs)) return -2;
    if (!rd32(umInst + cfg_num(umF[@"us"]), &us)) return -2;
    if (!(gs <= 7 && us <= 6)) return -2;   // 已知门（值域外 = 链还没就绪 / 偏移不对，不发布）
    BOOL needPage = (gs == 1 || gs == 5);
    if (needPage && !rd32(umInst + cfg_num(umF[@"page"]), &page)) return -2;
    int mode;
    if (gs == 7 || us == 3) {
        mode = 2;
        uint64_t handler;
        if (rd64(gmInst + cfg_num(gmF[@"inputHandler"]), &handler) && handler) {
            uint32_t skip;
            if (rd32(handler + cfg_num(_config[@"skipOffset"]), &skip) && skip <= 1) mode = 3;
        }
    } else if (gs == 2 || gs == 3 || gs == 6 || us == 2) mode = 1;
    else if (gs == 5 && page == (uint32_t)cfg_num(_config[@"bindingPage"])) mode = 6;
    else if (gs == 5) mode = 5;
    else if (gs == 1 && [self pageInMenuSet:page]) mode = 5;
    else if (gs == 1 && page == (uint32_t)cfg_num(_config[@"achievementsPage"])) mode = 7;
    else if (gs == 1 && page == (uint32_t)cfg_num(_config[@"bindingPage"])) mode = 6;
    else if ([_config[@"bagEnabled"] boolValue] && gs == 4) {
        NSDictionary *hero = _classes[@"Hero"];
        NSDictionary *heroF = [hero[@"fields"] isKindOfClass:NSDictionary.class] ? hero[@"fields"] : nil;
        uint64_t heroInst; uint8_t inv = 0;
        mode = (heroF && il2cpp_instance(main, cfg_num(hero[@"slot"]), cfg_num(hero[@"instanceOffset"]), &heroInst) &&
                rd8(heroInst + cfg_num(heroF[@"inv"]), &inv) && inv == 1) ? 4 : 0;
    }
    else mode = 0;
    if (_lastLogged[0] != (int)gs || _lastLogged[1] != (int)us || _lastLogged[2] != (int)page || _lastLogged[3] != mode) {
        _lastLogged[0] = (int)gs; _lastLogged[1] = (int)us; _lastLogged[2] = (int)page; _lastLogged[3] = mode;
        LOG("触屏显隐：[pad] state gs=%u us=%u page=%u → mode %d（%s）", gs, us, page, mode, _status.UTF8String);
    }
    return mode;
}
- (BOOL)pageInMenuSet:(uint32_t)page {
    for (id value in [_config[@"menuPages"] isKindOfClass:NSArray.class] ? _config[@"menuPages"] : @[])
        if (cfg_num(value) == page) return YES;
    return NO;
}
// 以撒派生（175 线 RE 定版）：模块数据段里的 g_Game 指针 → 日记词 / 暂停词，任一非 0 → 布局 C（模式 3），都为 0 → 局内（模式 2）。
//   链路与偏移全在配置 fields 里（gamePtr / diary / pause 的 chain），这里只做「按 chain 走指针 + 读 u32」。
- (int)pollDataFields {
    NSDictionary *module = [_config[@"module"] isKindOfClass:NSDictionary.class] ? _config[@"module"] : nil;
    NSString *needle = [module[@"nameContains"] isKindOfClass:NSString.class] ? module[@"nameContains"] : nil;
    if (!needle.length) return -2;
    module_t *m = mod_containing(needle.UTF8String); if (!m) return -2;
    NSDictionary *fields = [_config[@"fields"] isKindOfClass:NSDictionary.class] ? _config[@"fields"] : nil;
    uint64_t game = 0;
    if (![self readChain:fields[@"gamePtr"] module:m into:&game] || !game) return -2;
    uint32_t diary = 0, pause = 0;
    if (![self readFieldU32:fields[@"diary"] game:game value:&diary]) return -2;
    if (![self readFieldU32:fields[@"pause"] game:game value:&pause]) return -2;
    int mode = (diary != 0 || pause != 0) ? 3 : 2;
    if (_lastLogged[0] != (int)diary || _lastLogged[1] != (int)pause || _lastLogged[3] != mode) {
        _lastLogged[0] = (int)diary; _lastLogged[1] = (int)pause; _lastLogged[3] = mode;
        LOG("触屏显隐：[pad] diary=%u pause=%u → mode %d（%s）", diary, pause, mode, _status.UTF8String);
    }
    return mode;
}
// chain = [模块内偏移]（gamePtr 这种模块数据段里的指针）；走一步读指针
- (BOOL)readChain:(NSDictionary *)field module:(module_t *)m into:(uint64_t *)out {
    NSArray *chain = [field[@"chain"] isKindOfClass:NSArray.class] ? field[@"chain"] : nil;
    if (chain.count != 1) return NO;
    uint64_t off = cfg_num(chain[0]);
    if (off == UINT64_MAX || off + 8 > m->size) return NO;
    return rd64((uint64_t)m->base + off, out);
}
// chain = ["gamePtr", 字段偏移]：game 已解出，按偏移读 u32
- (BOOL)readFieldU32:(NSDictionary *)field game:(uint64_t)game value:(uint32_t *)out {
    NSArray *chain = [field[@"chain"] isKindOfClass:NSArray.class] ? field[@"chain"] : nil;
    if (chain.count != 2) return NO;
    uint64_t off = cfg_num(chain[1]);
    if (off == UINT64_MAX) return NO;
    return rd32(game + off, out);
}
@end
