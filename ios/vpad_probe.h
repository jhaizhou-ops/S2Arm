// 页值显隐探针：按 ios/vpad-data/visibility/<程序号>.json 的配置，10 Hz 读游戏状态、派生「页面模式」，
// vpad.m 按模式换按键集（标题 / 选项页只留少量键、键位页全键、日记 / 暂停页换 C 款布局……）。
//   派生语义照 nxnative 定版逐条对齐（页值表与模式键集全在配置里，通用层不写死任何一款的数字）；
//   读数器按 reader 种类分（il2cpp-singletons / module-data-fields），链路常量是该类运行时的布局常量。
// 诚实标注：配置里的槽位 / 偏移是对原版 NSO / NRO 逆的，S2Arm 的游戏是重写后的代码，未经真机实证前
//   配置 status 一律 unverified（见数据文件里的 statusNote）；读不到 / 不合规 → 不发布模式，
//   vpad 保持战斗布局（全键），绝不因为探针失败而隐藏按键。实证后把配置 status 改 verified。
// 线程：内部后台线程轮询并发布原子量；currentMode 等只读发布值，任意线程可读。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface S2AVPadProbe : NSObject
@property(nonatomic, readonly, copy) NSDictionary *config;
@property(nonatomic, readonly, copy) NSString *titleID;
@property(nonatomic, readonly, copy) NSString *status;   // 配置原样：unverified / verified
/// 该游戏在数据包里有探针配置才返回实例；没有返回 nil（vpad 不做任何显隐）
+ (nullable instancetype)probeForTitleID:(NSString *)titleID;
- (void)start;
- (void)stop;
/// 最近发布的模式：>= 0 已派生的已知模式；-1 还没派生过；-2 当前读不到（vpad 按战斗布局处理）
- (int)currentMode;
/// 配置里该模式的条目（keys / seats / sticks），没有返回 nil
- (nullable NSDictionary *)modeEntry:(int)mode;
/// 该模式下浮动摇杆是否响应：条目 sticks 显式写了听条目；没写时「键集为空 = 不响应、非空 = 响应」
- (BOOL)sticksEnabledForMode:(int)mode;
@end
NS_ASSUME_NONNULL_END
