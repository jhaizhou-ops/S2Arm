// vpad-data 数据包（ios/vpad-data/，随 App 打包：runtime/build.mk 把整目录拷进 .app 根）：
//   layouts/<程序号>.json      每游戏出厂布局预设（F01 格式，见 vpad_layout.h）
//   skins/<皮肤 id>/skin.json  按键皮肤包清单 + 每键图（见 vpad_skin.h）
//   visibility/<程序号>.json   页值显隐探针配置（见 vpad_probe.h）
// 通用层不写死任何一款游戏的数据：这里只做「按相对路径取包内文件」，解析在各自模块。
// 取不到（单测不带包、旧包没这目录）一律返回 nil，调用方回退到无预设 / 内置描线 / 无探针。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface S2AVPadData : NSObject
/// 包内 vpad-data 目录；不存在返回 nil
+ (nullable NSURL *)rootURL;
/// 相对路径（如 layouts/010013C00E930000.json）→ 包内文件 URL；不存在返回 nil
+ (nullable NSURL *)urlForRelativePath:(NSString *)relativePath;
+ (nullable NSData *)dataForRelativePath:(NSString *)relativePath;
/// 顶层是字典的 JSON；解析失败 / 不是字典返回 nil
+ (nullable NSDictionary *)jsonForRelativePath:(NSString *)relativePath;
@end
NS_ASSUME_NONNULL_END
