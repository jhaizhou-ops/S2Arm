// 按键皮肤包：ios/vpad-data/skins/<皮肤 id>/skin.json + 同目录每键图。
//   清单（schemaVersion 1）：{"id", "name", "games": [程序号…],
//     "buttons": {"A": {"normal": "a.png", "pressed": "a_p.png"}, …},   pressed 可缺（按下态由渲染方缩放代替）
//     "stick": {"base": "stick.png", "knob": "knob.png"}}               stick 可缺（摇杆保持内置石墨样式）
// 选了皮肤包，游戏内 vpad 与游戏库编辑器预览都按图画；没选（缺省）= 内置描线样式（同 vpad.m 方案三）。
// 选择按游戏存：偏好 suite S2AGame.<程序号> 的键 S2AVPadSkin（值 = 皮肤 id；无值 / 空 = 内置描线），
//   游戏库设置页写、游戏内 vpad 读同一处（与 S2AFps60 / S2AWidenForce 同一套按游戏偏好）。
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface S2AVPadSkin : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSArray<NSString *> *games;
@property(nonatomic, readonly, copy) NSURL *directory;   // 包目录（图相对它解析）
/// 包内全部皮肤包里适用于该游戏的（按 id 排序）；数据包缺失返回空数组
+ (NSArray<S2AVPadSkin *> *)skinsForGame:(NSString *)titleID;
/// 某键的图文件；pressed = YES 且清单没给按下图时返回 nil（渲染方自行用常态图 + 缩放表示按下）
- (nullable NSURL *)imageURLForButton:(NSString *)buttonID pressed:(BOOL)pressed;
- (nullable NSURL *)stickBaseURL;
- (nullable NSURL *)stickKnobURL;
/// 清单原样（游戏库编辑器预览经 C 接口拿它 + directory 拼图路径）
@property(nonatomic, readonly, copy) NSDictionary *manifest;
/// 本款当前选择：皮肤 id；nil = 内置描线（含选了已不存在的 id）
+ (nullable NSString *)selectedSkinIDForGame:(NSString *)titleID;
+ (void)selectSkinID:(nullable NSString *)skinID forGame:(NSString *)titleID;
@end
NS_ASSUME_NONNULL_END
